//
//  登録フォルダをライブラリとして有効化する [RG-01][LT-03]。
//
//  フェーズ 2 の成果（DB・パーサ・スキャン）がアプリから初めて呼ばれる場所。
//
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 有効化と初回スキャンの実処理。**フォルダツリーとメニューの両方から
/// 同じ実装を呼ぶ**——同じに見える操作に独立した経路を作ると、片方だけ
/// 直して取り残す（1-12 のアプリ関連付けで実際に踏んだ形）。
@MainActor
enum LibraryEnableAction {

    /// 有効化済みのライブラリを走査し直す [SY-05]。
    static func rescan(folder: RegisteredFolder, url: URL, locale: Locale,
                       openWindow: OpenWindowAction) {
        guard let summary = LibraryServices.shared.library(registrationUUID: folder.id) else { return }
        Task { await scan(libraryID: summary.id, displayName: folder.displayName,
                          url: url, locale: locale, openWindow: openWindow) }
    }

    /// ライブラリだけを手がかりに走査し直す [SY-05]。
    ///
    /// **根の URL を呼び出し側に要求しない。** 設定ウインドウのように
    /// フォルダツリーを持たない画面からも呼べるようにするため、登録フォルダの
    /// 解決をここで行う——View 越しに要求を回す作りにすると、メインウインドウが
    /// 閉じていると黙って何も起きない（実機検証でそうなった）。
    static func rescan(library: LibrarySummary, locale: Locale,
                       openWindow: OpenWindowAction) {
        Task {
            let folders = await RegisteredFolderStore.shared.folders(kind: .library)
                + RegisteredFolderStore.shared.folders(kind: .temporary)
            guard let folder = folders.first(where: { $0.id == library.uuid }),
                  let url = await RegisteredFolderStore.shared.resolvedURL(for: folder) else {
                await NotificationRouter.shared.presentError(
                    LibraryRootUnavailableError(displayName: library.displayName),
                    whatHappened: AppStrings.text("library.scan.failed", locale: locale))
                return
            }
            await scan(libraryID: library.id, displayName: library.displayName,
                       url: url, locale: locale, openWindow: openWindow)
        }
    }

    /// 登録ウィザードの確定 [RG3-25][RG3-26]。登録 → 有効化 → 初回走査を
    /// 1 本の経路で行う。**「登録」を押すまで DB には何も書かれていない**——
    /// ウィザードが集めた草案とフォルダをここで初めて永続化する。
    static func registerAndEnable(url: URL, displayName: String?,
                                  draft: LibrarySettingsDraft,
                                  template: LibraryTypeTemplate?,
                                  locale: Locale, openWindow: OpenWindowAction) {
        Task {
            // **切り離した行があれば同じ UUID で登録し直す** [RG4-03]。
            // `library.uuid` は登録フォルダ ID そのもの [07章 §7.3] なので、
            // ここで取り戻さない限り旧行は永久に孤児になる。判断は
            // `LibraryServices.detachedLibrary(matching:)` の 1 箇所にあり、
            // ウィザードは同じ関数を「引き継ぐと予告する」ためにも読む
            // ——規則は 1 つ、用途が 2 つ（表示と挙動）。
            let detached = await LibraryServices.shared.detachedLibrary(matching: url)
            let result: RegisteredFolderStore.RegistrationResult
            do {
                result = try await RegisteredFolderStore.shared.register(
                    url: url, kind: .library, displayName: displayName,
                    reusingID: detached?.uuid)
            } catch {
                await NotificationRouter.shared.presentError(
                    error,
                    whatHappened: AppStrings.text("folderTree.registrationFailedTitle",
                                         locale: locale))
                return
            }
            // 登録の増減はアプリ全体の信号で知らせる（フォルダツリーの
            // 登録ルート行は各行の監視ではなくこの信号で読み直す）。
            SessionState.shared.reloadToken += 1
            // 登録は通ったが知らせるべきこと [FS-06][NV-87]。
            if !result.warnings.isEmpty {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .warning, severity: .transient,
                    title: AppStrings.text("folderTree.registeredWithWarningTitle",
                                  locale: locale),
                    body: result.warnings
                        .map { registrationWarningDescription($0, locale: locale) }
                        .joined(separator: "\n")
                ))
            }
            if let detached {
                Log.app.info("切り離したライブラリへ結び直す [RG4-03]: \(Log.redactable(detached.displayName)) / ファイル \(detached.fileCount) 件 → \(Log.path(url))")
            }
            // 結び直しでは `enable` が冪等分岐で既存の行を返す——草案は使われず、
            // 以前の設定・ラベル・評価がそのまま生きる。
            await enable(folder: result.folder, url: url, draft: draft,
                         template: template, locale: locale, openWindow: openWindow)
        }
    }

    /// 登録時の警告 [FS-06][NV8-04] をユーザー向けの文にする。
    /// 登録の経路が 2 つ（ウィザード・テンポラリのパネル）あるため、
    /// 文言はここ 1 箇所に置く。
    static func registrationWarningDescription(_ warning: RegistrationWarning,
                                               locale: Locale) -> String {
        switch warning {
        case .networkVolumeFSEventsUnreliable:
            return AppStrings.text("folderTree.warning.networkVolume", locale: locale)
        case let .cloudSyncedLocation(provider):
            guard let provider else {
                return AppStrings.text("folderTree.warning.cloudSynced", locale: locale)
            }
            return String(
                format: AppStrings.text("folderTree.warning.cloudSyncedNamed", locale: locale),
                provider)
        }
    }

    static func disable(folder: RegisteredFolder) {
        Task {
            do {
                try await LibraryServices.shared.disable(registrationUUID: folder.id)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: AppStrings.text("library.disable.failed"))
            }
        }
    }

    /// 登録を解除する。ライブラリとして有効なら**先に**無効化する。
    ///
    /// **順序が規則の本体。** 逆にすると、解除でセキュリティスコープが閉じた
    /// あとに DB を触ることになり、失敗したときに「登録は消えたがライブラリ行は
    /// 残る」という一番片付けにくい状態を作る。フォルダツリーの「登録解除」と
    /// 制御口 [MT-33] の両方がここを通る——同じ規則を 2 か所に書かない。
    ///
    /// 確認ダイアログは**呼び出し側の責務**。ツリーは尋ねてからここへ来る。
    ///
    /// - Parameter keepData: **既定はデータを残す** [RG4-01]。残すと
    ///   ライブラリ行は生きたまま登録だけが消え（＝切り離し [RG4-02]）、
    ///   同じフォルダを登録し直せば結び直る [RG4-03]。
    static func unregister(folder: RegisteredFolder, disablingLibrary: Bool,
                           keepData: Bool = true) async throws {
        if disablingLibrary {
            try await LibraryServices.shared.disable(registrationUUID: folder.id,
                                                     keepData: keepData)
        }
        try await RegisteredFolderStore.shared.unregister(folder.id)
        // **登録が消えた後でなければ切り離しとして数えられない** [RG4-06]。
        // `disable` の中で数え直しても、そのときはまだ登録が残っている。
        await LibraryServices.shared.noteRegistrationsChanged()
    }

    /// 既存の登録を有効化する（起動時の再開ウィザード [§19.10 ステージ 2] の
    /// 確定）。**登録はし直さない**——`registerAndEnable` と違い、フォルダは
    /// もう `RegisteredFolderStore` にある。
    static func enableRegistered(folder: RegisteredFolder, url: URL,
                                 draft: LibrarySettingsDraft,
                                 template: LibraryTypeTemplate?,
                                 locale: Locale, openWindow: OpenWindowAction) async {
        await enable(folder: folder, url: url, draft: draft, template: template,
                     locale: locale, openWindow: openWindow)
    }

    // MARK: - 実処理

    private static func enable(folder: RegisteredFolder, url: URL,
                               draft: LibrarySettingsDraft,
                               template: LibraryTypeTemplate?, locale: Locale,
                               openWindow: OpenWindowAction) async {
        do {
            let id = try await LibraryServices.shared.enable(
                registrationUUID: folder.id,
                displayName: folder.displayName,
                url: url,
                bookmarkData: folder.bookmarkData,
                draft: draft,
                template: template)
            await scan(libraryID: id, displayName: folder.displayName, url: url,
                       locale: locale, openWindow: openWindow)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: AppStrings.text("library.enable.failed"))
        }
    }

    /// 走査そのもの。進捗は既存の受け皿（アプリ全体で 1 つの窓）へ流す [UI-09]。
    ///
    /// **取り消せるようにしておく** [A-04]。ライブラリは数万件になり得るので、
    /// 始めたら終わるまで止められない作りにしてはならない。ファイルシステムに
    /// 対しては読み取りしかしないため、途中で止めても利用者のファイルは変わらない。
    private static func scan(libraryID: LibraryID, displayName: String,
                             url: URL, locale: Locale,
                             openWindow: OpenWindowAction) async {
        let task = ScanTaskBox()
        let handle = OperationProgressCenter.shared.begin(
            title: String(format: AppStrings.text("library.scan.progressTitle", locale: locale),
                          displayName),
            cancel: { task.cancel() })
        defer { OperationProgressCenter.shared.finish(handle) }

        // ファイル単位の報告 [RG3-32] を 10 回/秒に間引いてから UI へ流す。
        // エンジンは間引かない（`ScanEngine.scan` の注記）——間引きは表示側の
        // 仕事で、実装は転送・展開と同じ `ProgressThrottle` を使う。
        // 副題は**件数**（転送と同じ鍵で「N 件中 M 件目 — 残り K 件」）。
        // ファイル名を渡してはいけない——進捗ウインドウは
        // `currentItemName` を自分の行で出すので、同じ名前が 2 行並ぶ
        // ［実機検証で発見、§19.10 ステージ 2］。
        let throttled = ProgressThrottle.wrap(ProgressReporter { progress in
            Task { @MainActor in
                OperationProgressCenter.shared.update(
                    handle, progress: progress,
                    detail: scanDetailText(progress, locale: locale))
            }
        }, totalItems: 0, totalBytes: 0)
        // この走査が操作履歴へ残す行を受け取る [NT-04]。走査結果の通知から
        // 「この操作を見る」で辿れるようにする。
        let logReceipt = OperationLogReceipt()
        do {
            let summary = try await task.run {
                try await LibraryServices.shared.scan(
                    libraryID: libraryID, root: url,
                    onProgress: { scan in
                        throttled.report(OperationProgress(
                            completedItems: scan.processed,
                            totalItems: scan.total,
                            currentItemName: scan.currentName))
                    },
                    logReceipt: logReceipt)
            }
            guard !summary.cancelled else { return }
            await notifyIfNoteworthy(summary, displayName: displayName,
                                     libraryID: libraryID, locale: locale,
                                     openWindow: openWindow,
                                     operationLogID: logReceipt.id)
            // **ここで要約を再掲しない。** `ScanEngine` が同じ数字を
            // `[Scan] スキャン完了` として既に書いており、二重に出るだけで
            // 情報が増えない。しかもこの関数は初回と再スキャンの両方から
            // 呼ばれるので、「初回スキャン完了」と書くと再スキャンのときに
            // 嘘になる（実機のログで実際にそうなっていた）。
        } catch is CancellationError {
            // 利用者が止めた。通知しない。
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: AppStrings.text("library.scan.failed"))
        }
    }


    /// 走査の結果のうち、**利用者が知るべきもの**だけを提示する
    /// [ER-01][ER-11][IF-05]。
    ///
    /// ## 何も無ければ黙る［ユーザー判断］
    /// 「今すぐ再スキャン」は日常的に走らせる操作なので、変化が無いのに毎回
    /// ダイアログが出ると、**本当に見てほしいときの 1 枚まで読み飛ばされる**
    /// ようになる。出すのは次の 3 つが 1 つでもあるときだけ:
    ///
    /// - **孤立**: 登録済みの実体が見つからなくなった [ID-06]。「ファイルが
    ///   消えた」という意味なので、黙って進めてよい情報ではない。
    /// - **未解決**: どのフォーマットにも一致しなかった [AL-31]。ラベルが
    ///   付かないまま埋もれる。
    /// - **1 冊扱いの解除**: 仕様が「通知する」と明示している [IF-05]。
    ///   孤立とは違い**実体はまだそこにある**ので、取り違えないよう別の文で書く。
    ///
    /// 成功そのものの要約は `ScanEngine` が診断ログへ書いている。
    ///
    /// - Note: どのファイルが孤立したかを一覧で見て片付ける手段
    ///   （`OR-01〜05` の整理ウインドウ）は 2-14 の担当［ユーザー判断: 今は
    ///   件数を知らせるだけにする］。ここで一覧を出す造りにはしない。
    /// 走査の進捗の副題。「2,501 件中 300 件目 — 残り 2,201 件」——転送
    /// （`FolderOperations.progressDetail`）と同じ鍵で見え方を揃える [RG3-32]。
    /// 列挙の段（総数が未確定＝ `totalItems == 0`）は見つけた件数だけを出す。
    ///
    /// 走査の `processed` は「いま処理しているファイルの通し番号」（1 始まり）
    /// なので、転送側と違い +1 しない。
    private static func scanDetailText(_ progress: OperationProgress,
                                       locale: Locale) -> String? {
        if progress.totalItems > 1 {
            let current = min(max(progress.completedItems, 1), progress.totalItems)
            var parts = [String(format: AppStrings.text("progress.itemCount", locale: locale),
                               current, progress.totalItems)]
            let remaining = progress.totalItems - current
            if remaining > 0 {
                parts.append(String(format: AppStrings.text("progress.remainingItems", locale: locale),
                                    remaining))
            }
            return parts.joined(separator: " — ")
        }
        if progress.completedItems > 0 {
            return String(format: AppStrings.text("progress.scanFound", locale: locale),
                          progress.completedItems)
        }
        return nil
    }


    /// 走査結果の題 [ID-06][AL-31][IF-05][EM-30]。**何が見つかったかで出し分ける**
    /// ［ユーザー指摘、2026-09-02］——1 種類しか無いときは名指しし、2 種類以上の
    /// ときだけ中立にする。判断は `ScanReviewTitle`（`QooApplication`）が持つ。
    private static func reviewTitle(_ summary: ScanSummary, displayName: String,
                                    locale: Locale) -> String {
        let subject = ScanReviewTitle.subject(
            orphaned: summary.orphaned,
            unresolved: summary.unresolvedNames,
            bookFoldersReleased: summary.bookFoldersReleased.count,
            volumeConflicts: summary.volumeConflicts)
        // **鍵は分岐の中に literal で書く**——変数に畳むと
        // `check-localization-keys` が鍵として認識できず、綴りを間違えても
        // 生の鍵が画面に出るまで気づけない。
        let template: String
        switch subject {
        case .unresolved:
            template = AppStrings.text("library.scan.reviewTitleUnresolved", locale: locale)
        case .orphaned:
            template = AppStrings.text("library.scan.reviewTitleOrphaned", locale: locale)
        case .bookFoldersReleased:
            template = AppStrings.text("library.scan.reviewTitleBookFolders", locale: locale)
        case .volumeConflicts:
            template = AppStrings.text("library.scan.reviewTitleVolumes", locale: locale)
        case .mixed, nil:
            template = AppStrings.text("library.scan.reviewTitle", locale: locale)
        }
        return String(format: template, displayName)
    }

    private static func notifyIfNoteworthy(_ summary: ScanSummary,
                                           displayName: String,
                                           libraryID: LibraryID?,
                                           locale: Locale,
                                           openWindow: OpenWindowAction,
                                           operationLogID: OperationLogID?) async {
        var lines: [String] = []
        if summary.orphaned > 0 {
            lines.append(String(format: AppStrings.text("library.scan.orphaned", locale: locale),
                                summary.orphaned))
        }
        var actions: [RecoveryAction] = []
        if summary.unresolvedNames > 0 {
            lines.append(String(format: AppStrings.text("library.scan.unresolved", locale: locale),
                                summary.unresolvedNames))
            // **整理ウインドウへの導線を出す** [UR2-02][AL-30]。孤立
            // （件数を知らせるだけ）と扱いを変えているのは、未解決は放置すると
            // **ラベルが 1 つも付かないまま蔵書に埋もれる**ため——ラベル
            // フィルタからは永久に辿り着けない。§4.11 が導線を名指ししている。
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewUnresolved,
                title: AppStrings.text("library.scan.reviewUnresolved", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewUnresolved)))
        }
        if !summary.bookFoldersReleased.isEmpty {
            lines.append(String(format: AppStrings.text("library.scan.bookFoldersReleased", locale: locale),
                                summary.bookFoldersReleased.count))
        }
        // **巻数の判断待ち** [EM-26][EM-31]。`ComicInfo.xml` の `Number` と
        // `Volume` が食い違っていて、どちらが巻数か機械的に決められない。
        // スキャンは止めずに走り切ってから、まとめて聞く。
        if summary.volumeConflicts > 0 {
            lines.append(String(format: AppStrings.text("library.scan.volumeConflicts", locale: locale),
                                summary.volumeConflicts))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewVolumes,
                title: AppStrings.text("library.scan.reviewVolumes", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewVolumes)))
        }
        guard !lines.isEmpty else { return }

        let chosen = await NotificationRouter.shared.present(NotificationItem(
            category: .warning,
            // **手動の再スキャンは従来どおり強度 2（シート）** [ER-02]。
            // 自分で走らせた操作の結果は、その場で見せるのが素直である
            // ——強度 4 へ移すと「押したのに何も出ない」ことになる。
            // 通知履歴には全強度が残る [NT-01 の改訂] ので、後から読み返せる。
            severity: .sheet,
            target: target(for: libraryID, displayName: displayName),
            title: reviewTitle(summary, displayName: displayName, locale: locale),
            body: lines.joined(separator: "\n"),
            actions: actions,
            operationLogID: operationLogID))

        // **ここでダイアログを出す。**要求を View 越しに回すと、メイン
        // ウインドウが閉じているときに黙って何も起きない［既知の失敗］。
        // 行き先の解決は `NotificationRouteAction` 1 箇所——通知履歴の行から
        // 押したときも同じ経路を通る [NT-05]。
        if let chosen, let libraryID {
            NotificationRouteAction.perform(actionID: chosen.id, libraryID: libraryID,
                                            locale: locale, openWindow: openWindow)
        }
    }

    /// 通知の対象 [NT-04]。**行 ID ではなく外部識別子（`library.uuid`）を持つ**
    /// ——登録解除で行 ID は再利用されうるし、通知は登録が消えたあとも残る。
    @MainActor
    private static func target(for libraryID: LibraryID?,
                               displayName: String) -> NotificationTarget? {
        guard let libraryID,
              let library = LibraryServices.shared.libraries.first(where: { $0.id == libraryID })
        else { return nil }
        return .library(uuid: library.uuid, name: library.displayName)
    }

    /// 自動走査（FSEvents の追随・定期フルスキャン）の結果を受け取る。
    ///
    /// **割り込まない。** 孤立 [ID-06]・未解決 [AL-31]・1 冊扱いの解除 [IF-05] は
    /// 強度 4 で履歴とバッジにだけ残す。以前ここでシートを出していた
    /// 「差し替えの確認待ち」[ID-05] は同一性確認の撤去 [§19.8] とともに消えた
    /// ——差し替えは走査が自動で引き継ぐので、割り込む理由が無くなった。
    ///
    /// 強度 4 は 1-12b の時点では出せなかった（提示先が無くログだけに
    /// なって届かない）。通知履歴とステータスバーのバッジ [NT-02] が
    /// できたことで初めて成立する。
    /// - Parameter operationLogID: その走査が操作履歴へ残した行 [NT-04]。
    @MainActor
    static func notifyAutomaticScan(libraryID: LibraryID, summary: ScanSummary,
                                    locale: Locale,
                                    operationLogID: OperationLogID?) {
        let library = LibraryServices.shared.libraries.first { $0.id == libraryID }
        let displayName = library?.displayName ?? ""
        let target = library.map { NotificationTarget.library(uuid: $0.uuid,
                                                              name: $0.displayName) }
        recordQuietFindings(summary, libraryID: libraryID, displayName: displayName,
                            target: target, locale: locale,
                            operationLogID: operationLogID)

    }

    /// 自動走査で同じ知らせを繰り返さないための番人 [NT-07]。
    /// **`ScanSummary` の件数は差分ではない**——理由は `ScanFindingsDigest` の doc。
    @MainActor
    private static let digest = ScanFindingsDigest()

    /// 割り込まずに履歴へ残す [OR2-05][UR2-02][IF-05][NT-01]。
    ///
    /// **何も無ければ黙る。** 変化があるたびに「12 件を取り込みました」と
    /// 残すと、外部でファイルを整理するだけで保持上限 1,000 件 [NT-07] を
    /// 数十回の操作で使い切る［ユーザー判断］。判断軸は手動の再スキャンと
    /// 同じにしてある——**どちらの経路でも同じものが残る。**
    ///
    /// **前回と同じ内容なら黙る** [`ScanFindingsDigest`]。差分走査は
    /// 恒久的に未解決なファイルを毎回数え直すので、これが無いと同じ行が
    /// 際限なく積み上がる［レビューで発見］。
    ///
    /// **導線は付ける。** 走査結果のシートに孤立の導線を足さないと決めた
    /// のは 2-14 の判断だが、それは**割り込むモーダルにボタンを増やさない**
    /// という話で、履歴の行は事情が違う——導線が無ければ、記録を読んでも
    /// そこから何もできない行き止まりになる。
    @MainActor
    private static func recordQuietFindings(_ summary: ScanSummary, libraryID: LibraryID,
                                            displayName: String,
                                            target: NotificationTarget?, locale: Locale,
                                            operationLogID: OperationLogID?) {
        let findings = ScanFindingsDigest.Findings(
            orphaned: summary.orphaned,
            unresolved: summary.unresolvedNames,
            bookFoldersReleased: summary.bookFoldersReleased.count)
        guard digest.shouldRecord(findings, for: libraryID) else { return }

        var lines: [String] = []
        var actions: [RecoveryAction] = []
        if summary.orphaned > 0 {
            lines.append(String(format: AppStrings.text("library.scan.orphaned", locale: locale),
                                summary.orphaned))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewOrphans,
                title: AppStrings.text("library.scan.reviewOrphans", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewOrphans)))
        }
        if summary.unresolvedNames > 0 {
            lines.append(String(format: AppStrings.text("library.scan.unresolved", locale: locale),
                                summary.unresolvedNames))
            actions.append(RecoveryAction(
                id: NotificationRouteAction.reviewUnresolved,
                title: AppStrings.text("library.scan.reviewUnresolved", locale: locale),
                kind: .openWindow(NotificationRouteAction.reviewUnresolved)))
        }
        if !summary.bookFoldersReleased.isEmpty {
            lines.append(String(format: AppStrings.text("library.scan.bookFoldersReleased",
                                               locale: locale),
                                summary.bookFoldersReleased.count))
        }
        guard !lines.isEmpty else { return }
        let item = NotificationItem(
            category: .warning,
            // 強度 4＝一時通知。**提示はされず履歴とバッジにだけ残る** [NT-02]。
            severity: .transient,
            target: target,
            title: reviewTitle(summary, displayName: displayName, locale: locale),
            body: lines.joined(separator: "\n"),
            actions: actions,
            operationLogID: operationLogID)
        Task { await NotificationRouter.shared.present(item) }
    }

    static func presentUnavailable(_ failure: StoreStartupFailure?) {
        Task {
            await NotificationRouter.shared.presentError(
                LibraryUnavailableError(failure: failure),
                whatHappened: AppStrings.text("library.unavailable"))
        }
    }
}

/// 取り消しのために走査タスクを掴んでおく箱。
@MainActor
private final class ScanTaskBox {
    private var handle: Task<ScanSummary, Error>?

    /// **`Task` に包んでから待つ**——`cancel()` は進捗の窓のボタンから
    /// 別の呼び出しとして届くので、取り消せる対象を掴んでおく必要がある。
    /// 呼び出し側の `await` をそのまま取り消させることはできない。
    func run(_ body: @escaping @Sendable () async throws -> ScanSummary) async throws -> ScanSummary {
        let task = Task { try await body() }
        handle = task
        return try await task.value
    }

    func cancel() { handle?.cancel() }
}

/// ライブラリ機能が使えないことを ER-03 の三要素で伝える。
struct LibraryUnavailableError: Error, UserPresentableError {
    let failure: StoreStartupFailure?

    var whatHappened: String { AppStrings.text("library.unavailable") }

    var whyItHappened: String {
        switch failure {
        case .schemaTooNew:
            AppStrings.text("library.unavailable.schemaTooNew")
        case .migrationFailed:
            AppStrings.text("library.unavailable.migrationFailed")
        case .templatesUnavailable:
            AppStrings.text("library.unavailable.templates")
        case .storeLocationUnavailable, .openFailed, .none:
            AppStrings.text("library.unavailable.openFailed")
        }
    }

    var recoverySuggestions: [RecoveryAction] { [] }
    var recoveryHint: String? { AppStrings.text("library.unavailable.hint") }
    var technicalDetail: String? {
        guard let failure else { return nil }
        return String(describing: failure)
    }
    var severity: NotificationSeverity { .sheet }
}

/// 走査したいのに根へ到達できない [1-17 の縮退状態]。
struct LibraryRootUnavailableError: Error, UserPresentableError {
    let displayName: String

    var whatHappened: String { AppStrings.text("library.rootUnavailable") }
    var whyItHappened: String { AppStrings.text("library.rootUnavailable.why") }
    var recoverySuggestions: [RecoveryAction] { [] }
    var recoveryHint: String? { AppStrings.text("library.rootUnavailable.hint") }
    var technicalDetail: String? { displayName }
    var severity: NotificationSeverity { .sheet }
}

/// 登録解除の確認 [RG-06][RG4-01]。
///
/// **既定はデータを残す。** チェックを入れたときだけ、ラベル・評価・保護
/// スコープ・手動タイトルまで連鎖削除する。残した場合は「切り離し」[RG4-02]
/// になり、同じフォルダを登録し直せばそのまま結び直る [RG4-03]。
///
/// 削除側を選んだときだけ、**自動バックアップの設定状態**を添える [RG4-07]
/// ——BK-07 の既定は 3 つとも OFF なので、既定の利用者は控えの無いまま
/// 取り返しのつかない削除をすることになる。ここから設定は変えさせない
/// （ダイアログの目的は「いま何が起きるか」を伝えることに絞る）。
struct LibraryUnregisterConfirmationDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    let folderName: String
    /// `true` ならライブラリのデータも消す。
    let onConfirm: (Bool) -> Void

    @State private var deletesData = false

    var body: some View {
        DialogScaffold(
            width: 420,
            confirm: DialogButton(
                title: AppStrings.text("folderTree.unregister", locale: locale),
                role: deletesData ? .destructive : nil
            ) { onConfirm(deletesData) },
            cancel: DialogButton(
                title: AppStrings.text("common.cancel", locale: locale), role: .cancel
            ) { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Tokens.spacing.s) {
                Text(String(
                    format: AppStrings.text("library.unregister.explanation", locale: locale),
                    folderName))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $deletesData) {
                    Text("library.unregister.deleteData")
                }
                Text(deletesData
                     ? AppStrings.text("library.unregister.warning", locale: locale)
                     : AppStrings.text("library.unregister.keepDataHint", locale: locale))
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if deletesData, !BackupService.configuredSnapshotsBeforeDestructive() {
                    Text("library.unregister.noBackupWarning")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
