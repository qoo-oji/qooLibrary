import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 中央ペイン（`FolderContentView`）とフォルダツリー（`FolderTreePane`）が
/// 共有するファイル操作レイヤ。
///
/// **なぜ独立した型にするのか** [ユーザー要望でフォルダツリーにも中央ペインと
/// 同じコンテキストメニューを付けたため]: 複製・コピー／カット・ペースト・
/// ゴミ箱・圧縮・展開・エイリアス・ロック・新規フォルダといった同じ操作を
/// 2 箇所で別々に実装すると、片方だけ直したときに挙動が静かにずれていく。
/// ここに一本化し、対象 URL と書き込み先フォルダを引数で受け取る形にする
/// ことで、「中央ペインは現在のフォルダ、ツリーは右クリックした行の親
/// フォルダ」といった違いを呼び出し側の引数だけで吸収する。
///
/// 守っている制約:
/// - すべての変更操作は `CommandStack.shared` 経由で実行する [A-03][UD-02]。
///   ファイルシステムの変更自体は各 `Command` が `FileOperationService` に
///   委譲する [FO-01][FO-02]。
/// - エラー提示は必ず `NotificationRouter` 経由 [ER-01]。
/// - 成功したら `SessionState.reloadToken` を必ず増分し、他ウインドウ／
///   ペインにも変更を伝える [1-6 実機検証で発見したクロスウインドウの表示
///   不整合対策、`SessionState.reloadToken` 参照]。呼び出し側が自分自身の
///   一覧を即座に更新したい場合は `onSuccess` を渡す（`reloadToken` 経由の
///   反映は次の Observation サイクルになるため、直後に選択・スクロールを
///   操作する経路ではタイミングが問題になり得る）。
///
/// この型は View ではないため `@Environment(\.locale)`/`@AppStorage` を
/// 使えない。表示言語は `AppLanguage.effectiveLocale`、環境設定は
/// `UserDefaults` の直接読み取りで参照する [1-12 ローカライズ方針、
/// `WindowState.loadDefaultListStyle()` と同じパターン]。設定値は操作を
/// 実行する瞬間に読むため、リアクティブな購読が無くても常に最新の値になる。
@MainActor
@Observable
final class FolderOperations {
    /// 圧縮・展開など数秒かかることがある処理の実行中表示 [UI-09]。
    /// 実際の描画は `.folderOperationsHost(_:)` が行う。
    var busyMessage: String?
    /// 暗号化が有効なときに圧縮前のパスワード設定シートを出すための保留状態。
    var pendingCompression: PendingCompression?
    /// 単一アーカイブ展開でパスワードが必要だった場合の再試行状態。
    var pendingExtractionPassword: PendingExtractionPassword?
    /// 完全削除の一連のダイアログ（確認 → ロック済み項目の判断）。
    ///
    /// **1 つの `@State` に enum でまとめる** — 確認シートを閉じた直後に
    /// ロック確認シートを出す、という連続した遷移になるため、別々の
    /// `.sheet` 修飾子を重ねると表示が不安定になりやすい
    /// [`FolderTreePane.FolderTreePrompt` が `.alert` で同じ理由の対処を
    /// している。既存の圧縮／展開パスワードシートは互いに独立した経路で
    /// 連続遷移しないため、そのまま個別の `.sheet` に残している]。
    var pendingDeletionStep: PermanentDeletionStep?

    private var locale: Locale { AppLanguage.effectiveLocale }

    /// [ER-11]「以降すべてに適用」が選ばれたあとの一括判断。1 回の完全削除
    /// 操作の間だけ有効で、次の操作の開始時にリセットする。
    private var lockedItemBlanketDecision: LockedItemDecision?

    // MARK: - コマンド実行の共通経路

    /// `CommandStack` でコマンドを実行し、成功時に `onSuccess` →
    /// `SessionState.reloadToken` 増分、失敗時に `NotificationRouter` への
    /// エラー提示までを行う唯一の経路。`command` が `nil`（対象が空で
    /// 実行するものが無い）なら何もしない。
    private func run(
        _ command: (any Command)?,
        failure: String.LocalizationValue,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard let command else { return }
        Task {
            do {
                _ = try await CommandStack.shared.run(command)
                onSuccess()
                SessionState.shared.reloadToken += 1
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: failure, locale: locale)
                )
            }
        }
    }

    /// 複数のコマンドを 1 回の操作として 1 つの Undo 単位にまとめる [UD-04]。
    /// 1 件ならそのまま返し、0 件なら `nil`（実行するものが無い）。
    static func singleOrComposite(_ commands: [any Command], displayName: String) -> (any Command)? {
        if commands.isEmpty { return nil }
        if commands.count == 1 { return commands[0] }
        return CompositeCommand(displayName: displayName, children: commands)
    }

    // MARK: - 基本のファイル操作

    /// [FM-02] 複製。書き込み先は呼び出し側が決める（中央ペインは現在の
    /// フォルダ、ツリーは対象フォルダの親）。
    func duplicate(_ urls: [URL], into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(CopyFilesCommand(items: urls, destination: destination), failure: "error.duplicateFailed", onSuccess: onSuccess)
    }

    /// [FM-04] ゴミ箱に入れる（Finder のゴミ箱と互換 [TR2-01]）。
    func moveToTrash(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(TrashCommand(items: urls), failure: "error.trashFailed", onSuccess: onSuccess)
    }

    // MARK: - 完全削除 [FM-14〜FM-18、8章 §8.5]

    /// [FM-14] ゴミ箱を経由しない完全削除。**必ず確認シートを挟む**
    /// [FM-15][PD-02][UD-10] — ここでは実行せず、確認状態を立てるだけ。
    /// 実際の実行は `runPermanentDeletion(_:)`（シートの決定ボタン）から。
    func deletePermanently(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        pendingDeletionStep = .confirm(PendingPermanentDeletion(urls: urls, onSuccess: onSuccess))
    }

    /// 確認シートで「削除」が押されたあとの実行本体。
    ///
    /// `CommandStack` 経由で実行するのは他の操作と同じだが、
    /// `DeletePermanentlyCommand.isUndoable == false` のため Undo スタックには
    /// 積まれない [PD-05]。操作履歴 [HS-01] には残る。
    func runPermanentDeletion(_ request: PendingPermanentDeletion) {
        // 「以降すべてに適用」は 1 回の削除操作ごとにリセットする [ER-11]。
        lockedItemBlanketDecision = nil
        busyMessage = String(localized: "permanentDelete.deleting", locale: locale)
        let command = DeletePermanentlyCommand(
            items: request.urls,
            options: DeletePermanentlyOptions(lockedItemResolver: { [self] url in
                await askLockedItemDecision(url)
            })
        )
        Task {
            defer { busyMessage = nil }
            do {
                _ = try await CommandStack.shared.run(command)
                request.onSuccess()
                SessionState.shared.reloadToken += 1
                await presentDeletionSummaryIfNeeded(command)
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.deletePermanentlyFailed", locale: locale)
                )
                SessionState.shared.reloadToken += 1
            }
        }
    }

    /// [PD-06][ER-11] ロック済み項目 1 件ごとの判断。「以降すべてに適用」が
    /// 選ばれていれば以後は尋ねずにその判断を使う。
    ///
    /// **継続（`CheckedContinuation`）は必ず 1 回だけ再開しなければならない。**
    /// シートを Esc 等で閉じた場合にボタンのコールバックが呼ばれないまま
    /// 終わると、この `await` が永久に返らずアプリが固まる。そのため
    /// `PendingLockedItem` 側で「一度しか呼ばれない」ことを保証し、
    /// 閉じられた場合は安全側の `.skip` で再開する。
    private func askLockedItemDecision(_ url: URL) async -> LockedItemDecision {
        if let blanket = lockedItemBlanketDecision { return blanket }
        return await withCheckedContinuation { continuation in
            let pending = PendingLockedItem(url: url) { [self] decision, applyToAll in
                if applyToAll { lockedItemBlanketDecision = decision }
                continuation.resume(returning: decision)
            }
            pendingDeletionStep = .lockedItem(pending)
            // **シートが実際に現れなかった場合の保険。**
            // 直前に確認シートを閉じたばかりのタイミングで次のシートを要求する
            // ため、SwiftUI が「閉じながら開く」要求を取りこぼすと、シートが
            // 一度も現れず `.onDisappear` の安全網も働かない。そうなると
            // ここの `await` が永久に返らず、「削除しています…」の表示のまま
            // アプリが操作不能になる（削除処理の途中なので影響も大きい）。
            //
            // 現れたかどうかは `didAppear` で判定するため、**ユーザーが
            // 長考している場合にこの保険が誤発動することはない**。
            Task { [weak pending] in
                try? await Task.sleep(for: .seconds(2))
                guard let pending, !pending.didAppear else { return }
                Log.ui.error("ロック確認シートが表示されませんでした。安全側にスキップします: \(url.lastPathComponent, privacy: .public)")
                pending.resolve(.skip, applyToAll: false)
                if case .lockedItem(let current) = pendingDeletionStep, current === pending {
                    pendingDeletionStep = nil
                }
            }
        }
    }

    /// [ER-12][ER-14] 完了後の結果サマリ。全件成功なら何も出さない
    /// （成功を報告するだけのダイアログは邪魔なため）。失敗・スキップが
    /// あった場合と、登録フォルダを強制解除した場合にだけ提示する。
    private func presentDeletionSummaryIfNeeded(_ command: DeletePermanentlyCommand) async {
        guard let outcome = command.outcome else { return }
        var lines: [String] = []
        if !outcome.failures.isEmpty || !outcome.skipped.isEmpty {
            lines.append(String(
                format: String(localized: "permanentDelete.summaryCounts", locale: locale),
                outcome.succeededCount, outcome.failures.count, outcome.skipped.count
            ))
            // [ER-14] 失敗は理由別の内訳が分かるようにまとめる。
            let byReason = Dictionary(grouping: outcome.failures, by: \.reason)
            for (reason, items) in byReason.sorted(by: { $0.value.count > $1.value.count }) {
                lines.append("• \(reason)（\(items.count)）: \(items.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", "))")
            }
        }
        if !command.unregisteredFolders.isEmpty {
            lines.append(String(
                format: String(localized: "permanentDelete.summaryUnregistered", locale: locale),
                command.unregisteredFolders.map(\.displayName).joined(separator: ", ")
            ))
        }
        guard !lines.isEmpty else { return }
        await NotificationRouter.shared.present(NotificationItem(
            category: outcome.failures.isEmpty ? .info : .warning,
            severity: .sheet,
            title: String(localized: "permanentDelete.summaryTitle", locale: locale),
            body: lines.joined(separator: "\n")
        ))
    }

    /// [FM-05] 名前を変更。名前が空、または変わっていなければ何もしない
    /// （Undo スタックへの無意味な積み増しを避ける）。
    func rename(_ url: URL, to newName: String, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        run(RenameCommand(item: url, newName: newName), failure: "error.renameFailed", onSuccess: onSuccess)
    }

    /// [FM-01] `parent` の中に新規フォルダを作る。
    func createFolder(named name: String, in parent: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !name.isEmpty else { return }
        run(CreateFolderCommand(url: parent.appendingPathComponent(name)), failure: "error.createFolderFailed", onSuccess: onSuccess)
    }

    /// Finder の「エイリアスを作成」。書き込み先は呼び出し側が決める。
    func createAliases(for urls: [URL], in destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        let children: [any Command] = urls.map { CreateAliasCommand(source: $0, destinationFolder: destination) }
        let command = Self.singleOrComposite(children, displayName: String(localized: "folder.createAlias", locale: locale))
        run(command, failure: "error.createAliasFailed", onSuccess: onSuccess)
    }

    /// Finder の「ロック」/「ロック解除」。
    func setLocked(_ urls: [URL], locked: Bool, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return }
        run(
            SetLockedCommand(items: urls, locked: locked),
            failure: locked ? "error.lockFailed" : "error.unlockFailed",
            onSuccess: onSuccess
        )
    }

    /// Finder の「選択項目で新規フォルダを作成」[Finder/Edit メニュー整備]。
    /// 新規フォルダの作成と選択項目の移動を 1 つの Undo 単位にまとめる [UD-04]。
    /// 衝突時にコマンド自体が失敗しないよう、事前にフォルダ名の空きを探す
    /// （Finder の「新規フォルダ」「新規フォルダ 2」…と同じ体裁）。
    func newFolderWithSelection(
        _ urls: [URL], in parent: URL,
        onSuccess: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let baseName = String(localized: "action.newFolderWithSelection.baseName", locale: locale)
        var candidate = parent.appendingPathComponent(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) \(suffix)")
            suffix += 1
        }
        let created = candidate
        let children: [any Command] = [
            CreateFolderCommand(url: created),
            MoveFilesCommand(items: urls, destination: created),
        ]
        let command = Self.singleOrComposite(children, displayName: String(localized: "action.newFolderWithSelection", locale: locale))
        run(command, failure: "error.newFolderWithSelectionFailed") { onSuccess(created) }
    }

    // MARK: - ペーストボード

    /// パスを改行区切りでテキストとしてコピーする [FM-10]。
    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Finder で対象を表示する [FM-09]。
    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// `⌘C`/コンテキストメニュー「コピー」。標準の `NSPasteboard` にファイル URL
    /// として書き込むため、Finder との相互運用（Finder へ貼り付け／Finder で
    /// コピーしたものをここへ貼り付け）が両方とも成立する。
    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        // 素のコピーはカット状態を打ち消す（さもないと直前のカットが
        // 後続のペーストで誤って移動として処理されてしまう）。
        SessionState.shared.cutURLs = []
    }

    /// `⌘X`/コンテキストメニュー「カット」[Finder/Edit メニュー整備の一環で追加]。
    /// Finder 自身のカット判定はプライベート API 頼りで他アプリと相互運用
    /// できないため、`SessionState.cutURLs`（アプリ内で完結する簡易な独自実装、
    /// 型のコメント参照）で「次のペーストは移動にする」ことだけを覚えておく。
    /// ペーストボードへの書き込み自体は `copyToPasteboard` と同じ（Finder への
    /// 貼り付け自体はコピーとして成立する。カットの伝搬はアプリ内ペースト時のみ）。
    func cutToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        SessionState.shared.cutURLs = Set(urls.map { $0.standardizedFileURL.path })
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    /// `⌘V`/コンテキストメニュー「ペースト」。ペーストボード上のファイル URL が
    /// 直前にカットされた集合と一致すれば移動、そうでなければコピー
    /// （Finder の `⌘V` と同じ既定）。**パス文字列（`standardizedFileURL.path`）で
    /// 比較する** — 生の `URL` 同士の `==` はペーストボード往復後の表現差異
    /// （末尾スラッシュ等）で一致しないことがあった [実機検証で発見、
    /// `SessionState.cutURLs` のコメント参照]。
    func paste(into destination: URL, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return }
        let isCutPaste = !SessionState.shared.cutURLs.isEmpty
            && Set(urls.map { $0.standardizedFileURL.path }) == SessionState.shared.cutURLs
        let command: any Command = isCutPaste
            ? MoveFilesCommand(items: urls, destination: destination)
            : CopyFilesCommand(items: urls, destination: destination)
        run(command, failure: "error.pasteFailed") {
            if isCutPaste { SessionState.shared.cutURLs = [] }
            onSuccess()
        }
    }

    // MARK: - 圧縮・展開 [9.4 節]

    /// `.tar.gz` のような複合拡張子も含めてアーカイブ名から拡張子を除いた
    /// ベース名を返す（展開先フォルダ名・圧縮先の既定名に使う）[AR-21]。
    static func archiveBaseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            return String(name.dropLast(".tar.gz".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// 現在の環境設定から `CompressionOptions` を組み立てる
    /// [環境設定「圧縮／展開」タブ、`CompressionPreferencesTab` と同じ
    /// `UserDefaults` キーを共有する]。
    var compressionOptions: CompressionOptions {
        let defaults = UserDefaults.standard
        return CompressionOptions(
            format: defaults.string(forKey: PreferenceKeys.compressionFormat).flatMap(CompressibleFormat.init(rawValue:)) ?? .zip,
            zipLevel: (defaults.object(forKey: PreferenceKeys.compressionZipLevel) as? Int).flatMap(ZipCompressionLevel.init(rawValue:)) ?? .normal,
            sevenZipCodec: defaults.string(forKey: PreferenceKeys.compressionSevenZipCodec).flatMap(SevenZipCodec.init(rawValue:)) ?? .ppmd,
            encryption: defaults.string(forKey: PreferenceKeys.compressionEncryption).flatMap(ArchiveEncryptionMethod.init(rawValue:)) ?? .none
        )
    }

    /// 展開時の安全上限 [EX-21、環境設定「圧縮／展開」タブ]。GB 単位で保存して
    /// いるため `ExtractLimits.maxUncompressedBytes`（バイト単位）へ変換する。
    var extractLimits: ExtractLimits {
        let defaults = UserDefaults.standard
        let defaultGB = Double(AppLimits.Extraction.defaultMaxUncompressedBytes) / 1_000_000_000
        let gb = defaults.object(forKey: PreferenceKeys.extractionMaxUncompressedGB) as? Double ?? defaultGB
        let entries = defaults.object(forKey: PreferenceKeys.extractionMaxEntries) as? Double ?? Double(AppLimits.Extraction.defaultMaxEntries)
        let ratioWarn = defaults.object(forKey: PreferenceKeys.extractionRatioWarn) as? Double ?? AppLimits.Extraction.defaultRatioWarn
        let ratioAbort = defaults.object(forKey: PreferenceKeys.extractionRatioAbort) as? Double ?? AppLimits.Extraction.defaultRatioAbort
        return ExtractLimits(
            maxUncompressedBytes: Int64(gb * 1_000_000_000),
            maxEntries: Int(entries),
            ratioWarn: ratioWarn,
            ratioAbort: ratioAbort
        )
    }

    /// [AR-10] 「ここに圧縮」。単一選択時は項目名、複数選択時は書き込み先
    /// フォルダ名を既定のアーカイブ名にする。暗号化が有効ならパスワードシートを
    /// 挟んでから実行する。
    func compressHere(
        _ urls: [URL], into destinationFolder: URL,
        onCompleted: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let name = urls.count == 1 ? Self.archiveBaseName(urls[0]) : destinationFolder.lastPathComponent
        beginCompression(PendingCompression(
            items: urls, destinationName: name, destinationFolder: destinationFolder,
            options: compressionOptions, conflictPolicy: .keepBoth, onCompleted: onCompleted
        ))
    }

    /// [AR-11] ファイル名・保存先を指定するダイアログ。zip/7z は環境設定の
    /// 既定形式に従う。
    func compressWithDialog(
        _ urls: [URL], startingIn folder: URL,
        onCompleted: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { return }
        let options = compressionOptions
        let ext = options.format == .zip ? "zip" : "7z"
        let defaultName = urls.count == 1 ? Self.archiveBaseName(urls[0]) : folder.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(ext)"
        panel.allowedContentTypes = options.format == .zip ? [.zip] : []
        panel.directoryURL = folder
        panel.prompt = String(localized: "folder.compressPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseSaveDestination", locale: locale)
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        beginCompression(PendingCompression(
            items: urls,
            destinationName: destinationURL.deletingPathExtension().lastPathComponent,
            destinationFolder: destinationURL.deletingLastPathComponent(),
            options: options,
            // NSSavePanel は既存ファイルの上書き確認を既に行っているため、
            // ここでは `.keepBoth`（自動連番）ではなく `.replace` にする。
            conflictPolicy: .replace,
            onCompleted: onCompleted
        ))
    }

    /// 暗号化の有無でパスワードシートを挟むかどうかを振り分ける。
    private func beginCompression(_ request: PendingCompression) {
        guard request.options.encryption != .none else {
            runCompression(request, passphrase: nil)
            return
        }
        pendingCompression = request
    }

    /// パスワードシートの確定後もここへ戻ってくる（`.folderOperationsHost(_:)`
    /// 参照）。
    func runCompression(_ request: PendingCompression, passphrase: String?) {
        busyMessage = String(localized: "folder.compressing", locale: locale)
        Task {
            defer { busyMessage = nil }
            do {
                // 完了後に作成したアーカイブを選択状態にするため、`CommandStack`
                // に渡す前に具体的な型のまま変数へ保持しておく（`CompressCommand`
                // は `final class` のため、`run(_:)` 実行後も同じインスタンスの
                // `resultURL` を読める）[ユーザー要望]。
                let command = CompressCommand(
                    items: request.items, destinationName: request.destinationName,
                    destinationFolder: request.destinationFolder,
                    options: request.options, passphrase: passphrase, conflictPolicy: request.conflictPolicy
                )
                _ = try await CommandStack.shared.run(command)
                SessionState.shared.reloadToken += 1
                if let resultURL = command.resultURL {
                    request.onCompleted(resultURL)
                }
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.compressFailed", locale: locale)
                )
            }
        }
    }

    /// 展開先フォルダを新規作成する場合は `CreateFolderCommand` + `ExtractCommand`
    /// を 1 つの Undo 単位にまとめる [UD-04]。複数アーカイブの一括展開も
    /// まとめて 1 単位にする（`MX2-08` の精神）。途中で失敗したら残りは中断する
    /// 暫定対応 [ER-20 の趣旨に近い、`BatchNotificationSession`〈結果サマリ・
    /// 部分失敗の集約〉はまだ実装していないため]。
    ///
    /// **パスワードの対話的な再試行は単一アーカイブ展開時のみ提供する**
    /// [環境設定「圧縮／展開」タブ、設計判断]。複数選択の一括展開中に
    /// パスワード保護されたアーカイブに遭遇した場合、どれが原因か・途中まで
    /// 成功した分をどう扱うかの UX が複雑になるため、通常のエラー表示に留める。
    func extract(
        _ urls: [URL], destination: @escaping (URL) -> URL,
        passphrase: String? = nil,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        guard !urls.isEmpty else { return }
        busyMessage = urls.count == 1
            ? String(localized: "folder.extractingOne", locale: locale)
            : String(format: String(localized: "folder.extractingCount", locale: locale), urls.count)
        let limits = extractLimits
        var children: [any Command] = []
        for url in urls {
            let target = destination(url)
            if !FileManager.default.fileExists(atPath: target.path) {
                children.append(CreateFolderCommand(url: target))
            }
            let entryPassphrase = urls.count == 1 ? passphrase : nil
            children.append(ExtractCommand(archiveURL: url, destination: target, limits: limits, passphrase: entryPassphrase))
        }
        let name = urls.count == 1
            ? String(format: String(localized: "folder.extractCommandName", locale: locale), urls[0].lastPathComponent)
            : String(format: String(localized: "folder.extractCommandNameCount", locale: locale), urls.count)
        guard let command = Self.singleOrComposite(children, displayName: name) else {
            busyMessage = nil
            return
        }
        Task {
            defer { busyMessage = nil }
            do {
                _ = try await CommandStack.shared.run(command)
                onSuccess()
                SessionState.shared.reloadToken += 1
            } catch let error as ExtractError where urls.count == 1 && (error == .passwordProtected || error == .incorrectPassphrase) {
                let retryMessage = error == .incorrectPassphrase ? String(localized: "error.incorrectPassphrase", locale: locale) : nil
                pendingExtractionPassword = PendingExtractionPassword(
                    archiveURL: urls[0], target: destination(urls[0]),
                    retryErrorMessage: retryMessage, onSuccess: onSuccess
                )
            } catch {
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.extractFailed", locale: locale)
                )
                onSuccess()
                SessionState.shared.reloadToken += 1
            }
        }
    }

    /// [AR-22] 展開先をユーザーに選ばせる。
    func extractToChosenDestination(_ urls: [URL], onSuccess: @escaping @MainActor () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "folder.extractPanelPrompt", locale: locale)
        panel.message = String(localized: "folder.chooseExtractDestination", locale: locale)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        extract(urls, destination: { _ in destination }, onSuccess: onSuccess)
    }

    /// `@AppStorage` を使えないこの型から環境設定を読むためのキー定義。
    /// **`CompressionPreferencesTab`/`FolderContentView` の `@AppStorage` と
    /// 同じ文字列でなければならない**ため、1 箇所にまとめて取り違えを防ぐ。
    enum PreferenceKeys {
        static let compressionFormat = "qoo.preferences.compression.format"
        static let compressionZipLevel = "qoo.preferences.compression.zipLevel"
        static let compressionSevenZipCodec = "qoo.preferences.compression.sevenZipCodec"
        static let compressionEncryption = "qoo.preferences.compression.encryption"
        static let extractionMaxUncompressedGB = "qoo.preferences.extraction.maxUncompressedGB"
        static let extractionMaxEntries = "qoo.preferences.extraction.maxEntries"
        static let extractionRatioWarn = "qoo.preferences.extraction.ratioWarn"
        static let extractionRatioAbort = "qoo.preferences.extraction.ratioAbort"
    }
}

// MARK: - 保留中のダイアログ状態

/// 圧縮の実行に必要な情報一式 [環境設定「圧縮／展開」タブ]。暗号化が有効な
/// ときはこの値をいったん `FolderOperations.pendingCompression` に保持して
/// パスワードシートを表示し、入力後に同じ値でそのまま実行する。
struct PendingCompression: Identifiable {
    let id = UUID()
    let items: [URL]
    let destinationName: String
    let destinationFolder: URL
    let options: CompressionOptions
    let conflictPolicy: ConflictPolicy
    /// 作成されたアーカイブの URL を受け取る。中央ペインが「作成した圧縮
    /// ファイルを選択してスクロールする」ために使う [ユーザー要望]。
    let onCompleted: @MainActor (URL) -> Void
}

/// 完全削除の一連のダイアログ。確認 → （ロック済み項目があれば）その判断、
/// という順に遷移する [FM-15][PD-06]。
enum PermanentDeletionStep: Identifiable {
    case confirm(PendingPermanentDeletion)
    case lockedItem(PendingLockedItem)

    var id: UUID {
        switch self {
        case .confirm(let request): request.id
        case .lockedItem(let request): request.id
        }
    }
}

/// ロック済み項目 1 件分の判断待ち [PD-06][ER-11]。
///
/// **`resolve` は高々 1 回しか下流へ伝わらない。** 呼び出し側は
/// `CheckedContinuation` を再開するためにこれを使っており、2 回再開すると
/// クラッシュ、0 回だと永久に待ち続けてアプリが固まる。シートのボタンと
/// `onDismiss`（Esc で閉じられた場合）の両方から呼ばれても安全なように、
/// ここで一度きりを保証する。
@MainActor
final class PendingLockedItem: Identifiable {
    let id = UUID()
    let url: URL
    /// シートが実際に表示されたか。表示されないまま終わった場合の保険
    /// （`FolderOperations.askLockedItemDecision` の見張り）が、ユーザーの
    /// 長考と「そもそも出なかった」を取り違えないようにするための印。
    var didAppear = false
    private var callback: ((LockedItemDecision, Bool) -> Void)?

    init(url: URL, onResolve: @escaping (LockedItemDecision, Bool) -> Void) {
        self.url = url
        self.callback = onResolve
    }

    /// - Parameter applyToAll: 「以降すべてに適用」[ER-11]
    func resolve(_ decision: LockedItemDecision, applyToAll: Bool) {
        guard let callback else { return }
        self.callback = nil
        callback(decision, applyToAll)
    }
}

/// 単一アーカイブ展開でパスワードが必要だった場合の再試行状態
/// [環境設定「圧縮／展開」タブ]。
struct PendingExtractionPassword: Identifiable {
    let id = UUID()
    let archiveURL: URL
    let target: URL
    let retryErrorMessage: String?
    let onSuccess: @MainActor () -> Void
}

// MARK: - 実行中表示・パスワードシートのホスト

extension View {
    /// `FolderOperations` の実行中表示（不定進捗オーバーレイ [UI-09]）と
    /// パスワードシートをこのビューに載せる。`FolderOperations` を使うビューは
    /// 必ず 1 回だけ適用する。
    func folderOperationsHost(_ operations: FolderOperations) -> some View {
        modifier(FolderOperationsHostModifier(operations: operations))
    }
}

private struct FolderOperationsHostModifier: ViewModifier {
    @Bindable var operations: FolderOperations

    func body(content: Content) -> some View {
        content
            .overlay {
                // 圧縮・展開は数秒かかることがあり、無表示だとアプリが固まった
                // ように見える。バイト単位の進捗（`ProgressReporter`）がまだ
                // 無いため不定進捗のみ表示する。
                if let busyMessage = operations.busyMessage {
                    ZStack {
                        Color.black.opacity(0.15)
                        QooProgressPresenter(title: busyMessage)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.m))
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(item: $operations.pendingCompression) { pending in
                ArchivePasswordSheet(mode: .setPassword) { password in
                    operations.runCompression(pending, passphrase: password)
                }
            }
            .sheet(item: $operations.pendingExtractionPassword) { pending in
                ArchivePasswordSheet(mode: .unlock(retryErrorMessage: pending.retryErrorMessage)) { password in
                    operations.extract(
                        [pending.archiveURL], destination: { _ in pending.target },
                        passphrase: password, onSuccess: pending.onSuccess
                    )
                }
            }
            // 完全削除の確認とロック済み項目の判断は連続して遷移するため、
            // 1 つの `.sheet` で切り替える（`PermanentDeletionStep` のコメント参照）。
            .sheet(item: $operations.pendingDeletionStep) { step in
                switch step {
                case .confirm(let request):
                    PermanentDeleteConfirmationSheet(request: request) {
                        operations.runPermanentDeletion(request)
                    }
                case .lockedItem(let request):
                    LockedItemDecisionSheet(request: request)
                }
            }
    }
}
