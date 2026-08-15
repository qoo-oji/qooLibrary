import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// D&D の共通処理 [DD-01〜DD-05]。すべて `FileOperationService` 経由 [FO-01]。
/// `Command`（`QooApplication`）が `@MainActor` プロトコルのため、それを
/// 構築するこの型も `@MainActor` にする（呼び出し元は SwiftUI の View
/// クロージャのみで、元々すべて MainActor 上だった）。
@MainActor
enum DropHandling {
    /// 本物の Finder と同じ規則 [DD-01][設計判断]: 同一ボリューム内のドラッグは既定で
    /// 移動、異なるボリューム間（Finder からの取り込みを含む）のドラッグは既定でコピー。
    /// Option キーはどちらの場合も既定動作を反転させる。SwiftUI の
    /// `dropDestination(for:action:)`/`onDrag` はモディファイアキーの状態を渡してこない
    /// ため、ドロップ確定時点の `NSEvent.modifierFlags` を見て判定する。
    /// 複数アイテムのドロップでボリュームが混在する場合はアイテムごとに判定する。
    /// - Parameter operations: 衝突の判断・進捗・キャンセルを担う共有レイヤ
    ///   [FM-11][UI-09]。D&D も他の経路と同じ体験になるよう必ず通す。
    static func performDrop(
        _ urls: [URL],
        into destination: URL,
        operations: FolderOperations,
        onComplete: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void = { message in
            // すべての呼び出し元は現状 `onFailure` を明示的に渡しているため
            // 通常はここに到達しないが、渡し忘れた場合の保険として
            // `NotificationRouter` 経由にしておく（以前はログのみで、
            // D&D の失敗がユーザーに一切見えなかった [ER-01 違反、1-12b で解消]）。
            Task {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .error, severity: .sheet,
                    title: String(localized: "error.operationFailed", locale: AppLanguage.effectiveLocale),
                    body: message
                ))
            }
        }
    ) {
        let targets = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path != destination.standardizedFileURL.path
        }
        guard !targets.isEmpty else { return }
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        var copyTargets: [URL] = []
        var moveTargets: [URL] = []
        for url in targets {
            let defaultIsCopy = !isSameVolume(url, destination)
            if optionHeld != defaultIsCopy {
                copyTargets.append(url)
            } else {
                moveTargets.append(url)
            }
        }

        // [FM-11] 衝突したら尋ねる。進捗とキャンセルも同じ経路で付く。
        let options = operations.transferOptions()
        // コピー・移動が両方混在する 1 回の D&D ジェスチャは、1-11 の
        // Undo 基盤で 1 つの Undo 単位にまとめる [UD-04]。
        var children: [any Command] = []
        if !copyTargets.isEmpty {
            children.append(CopyFilesCommand(items: copyTargets, destination: destination, options: options))
        }
        if !moveTargets.isEmpty {
            children.append(MoveFilesCommand(items: moveTargets, destination: destination, options: options))
        }
        guard !children.isEmpty else { return }
        let command: any Command = children.count == 1
            ? children[0]
            : CompositeCommand(
                displayName: String(localized: "command.dragAndDrop", locale: AppLanguage.effectiveLocale),
                children: children
            )
        // **`CommandStack` を直に呼ばない** — 進捗・キャンセル・エラー提示を
        // 他の経路と同じ 1 本にそろえる [レビューで発見]。
        operations.runDrop(command, isMove: copyTargets.isEmpty, onComplete: onComplete)
        _ = onFailure
    }

    /// ボリュームが判定できない場合は異なるボリューム扱い（既定コピー、安全側）にする。
    /// `VolumeEligibilityChecker` と同じ `.volumeUUIDStringKey` を使う（`.volumeURLKey`
    /// はサンドボックス配下のフォルダ一覧経路で解決に失敗することがあった）。
    private static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard
            let uuidA = try? a.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
            let uuidB = try? b.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        else {
            return false
        }
        return uuidA == uuidB
    }
}
