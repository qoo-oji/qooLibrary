#if DEBUG
import AppKit
import Foundation
import QooApplication
import QooInfrastructure
import QooKit
import QooUI
import SwiftUI

/// 制御口 [MT-33][§16.8] へ、アプリ層でしか呼べない操作を足す。
///
/// **ここに置くのは層の向きのため** [A-01]。口の本体は `QooUI` にあるが、
/// 登録・走査・解除を起こす `LibraryEnableAction` はその上のこの層に居る。
/// 差し込み（`ControlExtensions`）なら層を 1 つも壊さずに、**UI が押すのと
/// 同じ関数**をそのまま呼べる。
///
/// **口専用の経路を作らない** [CT-09]。どのハンドラも、ウィザードやツリーの
/// メニューが呼ぶのと同じ関数を呼ぶ。
@MainActor
enum ControlAppCommands {
    static func register() {
        ControlExtensions.register("library:list") { _ in await list() }
        ControlExtensions.register("library:register") { await register($0) }
        ControlExtensions.register("library:unregister") { await unregister($0) }
        ControlExtensions.register("library:scan") { await scan($0) }
        ControlExtensions.register("progress:list") { _ in progress() }
    }

    // MARK: - 一覧

    private static func list(_: [String: Any] = [:]) async -> ControlOutcome {
        let services = LibraryServices.shared
        var folders: [[String: Any]] = []
        for kind in [RegisteredFolderKind.library, .temporary] {
            for folder in await RegisteredFolderStore.shared.folders(kind: kind) {
                var node: [String: Any] = [
                    "uuid": folder.id.uuidString,
                    "kind": kind == .library ? "library" : "temporary",
                    "displayName": ControlRedaction.apply(folder.displayName),
                    "enabled": services.isEnabled(registrationUUID: folder.id),
                ]
                if let library = services.library(registrationUUID: folder.id) {
                    node["libraryID"] = library.id.rawValue
                    node["online"] = library.isOnline
                }
                folders.append(node)
            }
        }
        return ControlOutcome.success([
            "folders": folders,
            "presets": services.presetTemplates.map(\.key),
            "userTemplates": services.userTemplates.map { $0.id.uuidString },
        ])
    }

    // MARK: - 登録

    /// 登録 → 有効化 → 初回走査。**ウィザードの確定と同じ関数**
    /// （`LibraryEnableAction.registerAndEnable`）を呼ぶ [RG3-26]。
    ///
    /// **これで `NSOpenPanel` の壁が消える** ——フォルダ選択は別プロセスが
    /// 描くので口からは駆動できず、登録が丸ごと GUI に縛られていた。
    /// パネルが担うのは「どのフォルダか」を決めることだけで、その先の
    /// 経路は同じである。
    ///
    /// **走査の完了は待たない** [CT-15]。`registerAndEnable` は `Task` を
    /// 起こして即座に返る作りで、口の応答はメインを塞がずに返す必要がある。
    /// 終わったかは `progress:list` で見る。
    private static func register(_ args: [String: Any]) async -> ControlOutcome {
        guard let path = args["path"] as? String else { return ControlOutcome.failure("path が要ります") }
        let services = LibraryServices.shared
        guard services.isReady else { return ControlOutcome.failure("ストアがまだ開いていません") }
        guard let volumeSets = services.volumeSetDefinition else {
            return ControlOutcome.failure("巻数フォーマットの定義を読めていません")
        }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ControlOutcome.failure("フォルダがありません: \(ControlRedaction.apply(path))")
        }

        // 起点は 3 通り（プリセット・ユーザー定義・白紙）。**ウィザードと
        // 同じ関数で草案にする** [§15.16]——ここで別の作り方をすると、口で
        // 登録したライブラリと画面から登録したライブラリが微妙に違う。
        let key = args["template"] as? String
        let displayName = args["displayName"] as? String ?? url.lastPathComponent
        let vocabulary = (try? BuiltInTemplates.bookTypes()) ?? []
        var template: LibraryTypeTemplate?
        let draft: LibrarySettingsDraft
        switch key {
        case nil, "custom":
            draft = TemplateInstantiation.blankDraft(
                volumeSets: volumeSets, displayName: displayName,
                defaultFieldNames: DefaultFieldNames.localized,
                bookTypeVocabulary: vocabulary)
        case let key?:
            if let preset = services.presetTemplates.first(where: { $0.key == key }) {
                template = preset
                draft = TemplateInstantiation.draft(
                    from: preset, volumeSets: volumeSets, displayName: displayName,
                    bookTypeVocabulary: vocabulary)
            } else if let user = services.userTemplates.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name == key
            }) {
                draft = user.settings.draft(displayName: displayName,
                                            bookTypeVocabulary: vocabulary)
            } else {
                return ControlOutcome.failure("テンプレートがありません: \(key)")
            }
        }

        LibraryEnableAction.registerAndEnable(
            url: url, displayName: displayName, draft: draft, template: template,
            locale: AppLanguagePreference.effectiveLocale, openWindow: openWindow())
        return ControlOutcome.success([
            "started": true,
            "path": ControlRedaction.apply(path),
            "template": key ?? "custom",
        ])
    }

    // MARK: - 解除

    /// **確認ダイアログは通らない。** あれは「何が失われるか」を伝えるための
    /// もので、押した先の処理はこの関数と同じ [ER-01]。ダイアログ自体は
    /// `ctx:dump` で別に確かめられる。
    private static func unregister(_ args: [String: Any]) async -> ControlOutcome {
        guard let folder = await folder(for: args, allowingOnly: false) else {
            return ControlOutcome.failure("uuid か name で対象を指してください（解除は取り消せません）")
        }
        let disabling = LibraryServices.shared.isEnabled(registrationUUID: folder.id)
        // **既定は削除**（`keepData: true` を渡したときだけ残す）[RG4-09]。
        // GUI 側の既定は逆（残す）だが、口の既定を反転させると後始末で
        // 「DB が全テーブル 0 件に戻る」ことを確かめている既存の検証手順が
        // 黙って通らなくなる——破壊的な側を既定にするのは、口の呼び出しを
        // 壊さないため。
        let keepData = args["keepData"] as? Bool ?? false
        do {
            try await LibraryEnableAction.unregister(folder: folder, disablingLibrary: disabling,
                                                     keepData: keepData)
        } catch {
            return ControlOutcome.failure("登録解除に失敗しました: \(error)")
        }
        SessionState.shared.reloadToken += 1
        return ControlOutcome.success(["unregistered": folder.id.uuidString,
                                       "disabledLibrary": disabling,
                                       "keptData": disabling && keepData])
    }

    // MARK: - 走査

    private static func scan(_ args: [String: Any]) async -> ControlOutcome {
        guard let folder = await folder(for: args, allowingOnly: true) else {
            return ControlOutcome.failure("登録が見つかりません")
        }
        guard let library = LibraryServices.shared.library(registrationUUID: folder.id) else {
            return ControlOutcome.failure("ライブラリとして有効になっていません")
        }
        LibraryEnableAction.rescan(library: library,
                                   locale: AppLanguagePreference.effectiveLocale,
                                   openWindow: openWindow())
        return ControlOutcome.success(["started": true, "libraryID": library.id.rawValue])
    }

    // MARK: - 進捗

    /// **走ったことの確認にも、終わったことの確認にも使う** [CT-15]。
    /// 口は時間のかかる操作を待たずに返すので、完了はここを見て判断する。
    private static func progress() -> ControlOutcome {
        let operations = OperationProgressCenter.shared.operations.map { operation -> [String: Any] in
            var node: [String: Any] = [
                "title": ControlRedaction.apply(operation.title),
                "paused": operation.isPaused,
            ]
            if let fraction = operation.fraction { node["fraction"] = fraction }
            if let detail = operation.detail { node["detail"] = ControlRedaction.apply(detail) }
            return node
        }
        return ControlOutcome.success(["operations": operations, "busy": !operations.isEmpty])
    }

    // MARK: - 補助

    /// 対象の登録を選ぶ。
    ///
    /// **`allowingOnly` は破壊的なコマンドでは使わない。** 「1 件しか無ければ
    /// それを対象にする」という便宜は、`library:unregister` を引数なしで
    /// 叩いたときに**唯一の登録を黙って解除する**（有効なライブラリなら
    /// 手動ラベル・評価・手動タイトルが連鎖で消え、BK-07 は既定 3 つとも
    /// OFF なので控えも無い）。**取り返しのつかない操作は必ず指させる。**
    private static func folder(for args: [String: Any],
                               allowingOnly: Bool) async -> RegisteredFolder? {
        let all = await RegisteredFolderStore.shared.folders(kind: .library)
            + RegisteredFolderStore.shared.folders(kind: .temporary)
        if let uuid = args["uuid"] as? String {
            return all.first { $0.id.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }
        }
        if let name = args["name"] as? String {
            return all.first { $0.displayName == name }
        }
        return allowingOnly && all.count == 1 ? all.first : nil
    }

    /// **ヘッドレスでは開く先のシーンが無い。** `EnvironmentValues()` から
    /// 取れる既定の動作をそのまま渡す——口が検証したいのは登録と走査の経路で
    /// あって、走査結果のシートからウインドウが開くことではない（そこは
    /// `ctx:*`／`ax:press` で別に確かめる）。
    private static func openWindow() -> OpenWindowAction {
        EnvironmentValues().openWindow
    }
}
#endif
