import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

/// 右ペイン（インスペクタ）[14章 §14.4、DT-01〜DT-07/DT-10]。単一選択時は
/// すべての情報、複数選択時は共通情報のみを表示する [RP-02]。何も選択されて
/// いない場合は現在のフォルダ自身の情報を表示する（Finder には無い挙動だが、
/// 常設インスペクタとして常に何か表示されている方が有用なため）[設計判断]。
///
/// **評価 [RA-01〜RA-08]・ラベル [RL-01〜RL-07]・タイトル [RP-10〜RP-12]・
/// カバー画像 [CV-01〜CV-08] は実装済み**（それぞれ `InspectorRatingSection` /
/// `InspectorLabelSection` / `InspectorTitleSection` / `InspectorCoverSection`）。
/// アプリの関連付け表示 [DT-07] とアーカイブ状態 [DT-11] は未実装——前者は
/// 表示の置き場所を決めていないため、後者はファイル保管庫（2-11）が無いため。
struct InspectorPane: View {
    @Environment(\.locale) private var locale
    let folder: URL?
    let selection: Set<URL>
    /// カバー画像の表示もサムネイル一括トグルに従う [DS-06][CV2-01]。
    let thumbnailsHidden: Bool
    /// 表示中のライブラリ [RA-01]。ボリューム経由で開いているなら `nil`。
    /// **URL から逆算しない**——`NavigationRoot` の約束に従い、判定は
    /// 呼び出し側（`MainWindowView`）の責務（`LabelFilterModel` と同じ）。
    let library: LibrarySummary?

    private var targets: [URL] {
        if selection.isEmpty {
            return folder.map { [$0] } ?? []
        }
        return Array(selection)
    }

    var body: some View {
        Group {
            if targets.isEmpty {
                PlaceholderPane(title: String(localized: "inspector.title", locale: locale), subtitle: "")
            } else if targets.count == 1 {
                SingleItemInspector(
                    url: targets[0], thumbnailsHidden: thumbnailsHidden,
                    // **何も選んでいないときは評価欄を出さない**［設計判断］。
                    // その場合ここが描いているのは「いま居る場所」であって、
                    // 利用者が選んだ項目ではない——立っている場所に星を付ける
                    // 操作は意味を成さないし、ライブラリを歩くあいだずっと
                    // 「評価できません」が常駐することになる。ブックフォルダ
                    // [RA-08] は 1 冊として親の一覧に並ぶので、そちらで選べる。
                    library: selection.isEmpty ? nil : library)
            } else {
                // [RP-02] 複数選択でも共通情報＋ラベルの一括付与／削除を出す。
                // ここは必ず「選んだ項目」なので、単一選択のときのような
                // 「現在のフォルダを描いている」場合分けは要らない。
                MultiItemInspector(urls: targets, library: library)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SingleItemInspector: View {
    @Environment(\.locale) private var locale
    let url: URL
    let thumbnailsHidden: Bool
    let library: LibrarySummary?

    /// 評価 [RA-01〜RA-08]。判定は `QooApplication` 側が持つ。
    @State private var rating = RatingEditorModel()
    /// タイトル [RP-10〜RP-12][DT-08][DT-09]。同上。
    @State private var title = TitleEditorModel()
    /// カバー画像 [CV-01〜CV-08]。同上。
    @State private var cover = CoverEditorModel()
    /// ラベル設定 [RL-01〜RL-07]。同上。
    @State private var labels = LabelEditorModel()
    @State private var protection = ProtectionEditorModel()
    /// 保管庫 [FA-01][FA-07][DT-11]。
    @State private var vault = VaultEditorModel()
    /// 未整理 [UR3-04][UR2-05]。同上。
    @State private var unresolved = UnresolvedHintModel()
    /// 書き込みのあと一覧と件数を読み直すための合図。**`.task(id:)` の鍵に
    /// 入れる**——`operationHistory` の増分でも読み直せるが、ダイアログから
    /// 作った新しいラベルは一覧に無いので、書いた側から明示的に促す。
    @State private var labelRevision = 0

    @State private var info: FileDetailInfo?
    @State private var containedCounts: ContainedCounts?
    /// 中身を数えられなかった [DT-05][DT-06]。**「まだ数えている」と区別する**
    /// ——区別しないとスピナーが永久に回り続ける［ユーザーが実機で指摘］。
    /// 壊れたアーカイブ・対応していない形式で起こる。
    @State private var containedCountsUnreadable = false
    /// この項目を含むフォルダを見張る [10章 §10.0]。項目が外部で消された・
    /// 改名された・書き換えられたときに、詳細が古いまま残らないようにする。
    @State private var parentWatch = DirectoryObservation()
    /// 対象がフォルダのときだけ、その**直下**も見張る。含まれるファイル数・
    /// 合計サイズ [DT-05][DT-06] が変わる主な原因は直下の項目の増減だから。
    ///
    /// **配下すべて（`.deep`）にはしない** [レビューで指摘、設計判断]。
    /// この集計は毎回フォルダ全体を数え直す（Phase 2 で DB にキャッシュする
    /// までの暫定）。孫以下の変更でも数え直す作りにすると、活発に書き換わって
    /// いるフォルダを選んでいる間、走査が完了する前に打ち切られては始まり直す
    /// ことを繰り返し、数字がいつまでも出ないまま CPU を焼き続ける。
    /// 深い階層の変更は、選び直したときとアプリが前面に戻ったときに反映される。
    @State private var subtreeWatch = DirectoryObservation()
    /// 直近で読み込んだ対象。**同じ対象の読み直しでは表示を消さない**ため
    /// に持つ — 外部の変更で読み直すたびにスピナーへ戻ると、変化のたびに
    /// 内容が消えてちらつく。対象そのものが変わったときだけ白紙に戻す。
    @State private var loadedURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                InspectorCoverSection(url: url, thumbnailsHidden: thumbnailsHidden,
                                      model: cover) // [CV-01〜CV-08]
                Text(url.lastPathComponent)
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                    .lineLimit(3)

                // **並びは「普通のフォルダと共通の情報 → ライブラリ固有の情報」**
                // ［ユーザー指定、2026-09-02］。上半分はどのファイルにもある
                // もの（種類・大きさ・日付・場所）、下半分は蔵書としての情報
                // （評価・基本情報・ラベル・保護・保管庫・未整理）。
                if let info {
                    Divider()
                    InspectorRow("column.kind", value: info.kindDescription) // [DT-04]
                    // **実体がファイルのときだけ出す。** ディレクトリの
                    // `fileSize` は `nil` なので、パッケージをファイル扱いに
                    // すると「0 KB」と表示されてしまう [実機検証で発見]。
                    if !info.isDirectory {
                        InspectorRow("column.size", value: Self.sizeFormatter.string(fromByteCount: info.size ?? 0)) // [DT-03]
                    }
                    InspectorRow("column.creationDate", value: info.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "—") // [DT-01]
                    InspectorRow("column.modificationDate", value: info.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—") // [DT-02]

                    if info.isNavigableFolder || info.isArchive {
                        Divider()
                        if containedCountsUnreadable {
                            // **回り続けるスピナーを見せない** [ER-01 の精神]。
                            // 「数えられなかった」は結果であって、進行中ではない。
                            InspectorRow("inspector.containedFileCount",
                                         value: String(localized: "inspector.containedUnreadable",
                                                       locale: locale))
                        } else if let containedCounts {
                            InspectorRow("inspector.containedFileCount", value: "\(containedCounts.fileCount)") // [DT-05]
                            InspectorRow("inspector.containedFolderCount", value: "\(containedCounts.folderCount)") // [DT-06]
                            if info.isNavigableFolder {
                                InspectorRow("inspector.totalContentSize", value: Self.sizeFormatter.string(fromByteCount: containedCounts.totalSize))
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Divider()
                    InspectorRow("inspector.location") {
                        Text(url.deletingLastPathComponent().path)
                            .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    InspectorRow("inspector.fullPath") { // [DT-10]
                        Text(url.path)
                            .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }

                    // ここから下はライブラリの中でだけ意味を持つ情報。
                    // **並びは 基本情報 → ラベル → 評価 → 保護**［ユーザー指定、
                    // 2026-09-02］——名前を決めるもの、分類するもの、主観の
                    // 評価、そして全部まとめて守る操作、という順。
                    InspectorTitleSection(model: title) // [RP-10〜RP-12][DT-08][DT-09]
                    InspectorLabelSection(model: labels) { labelRevision &+= 1 } // [RL-01〜RL-07]
                    InspectorRatingSection(model: rating) // [RA-01〜RA-08]
                    InspectorProtectionSection(model: protection)   // [PR-05]
                    InspectorVaultSection(model: vault) // [FA-01][FA-07][DT-11]
                    InspectorUnresolvedSection(model: unresolved) // [UR3-04][UR2-05]
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(Tokens.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.task(id: url)` は選択が変わるたびに前のタスクを自動キャンセルする
        // ため、大きなフォルダを選んだ直後に別の項目へ切り替えても古い集計が
        // 表示され続けることはない。
        .task(id: ReloadKey(url: url, generation: parentWatch.generation &+ subtreeWatch.generation)) {
            if loadedURL != url {
                info = nil
                containedCounts = nil
                containedCountsUnreadable = false
                loadedURL = url
            }
            // **メインスレッドで `resourceValues` を呼ばない** [NV6-02]。
            // 選択を動かすたびに走るうえ、相手が応答しなければそこで止まる。
            info = await FileIO.perform { Self.loadInfo(for: url) }
            guard let info, info.isNavigableFolder || info.isArchive else { return }
            // 打ち切られた場合は `nil` が返る。**途中まで数えた値を表示しない**
            // [レビューで発見]。`Task.detached` をやめてキャンセルが実際に
            // 伝わるようになったことで、それまで起こり得なかったこの経路が
            // 生きるようになった。
            switch await Self.computeContainedCounts(for: url, isArchive: info.isArchive) {
            case .counted(let counts):
                containedCounts = counts
                containedCountsUnreadable = false
            case .unreadable:
                // 壊れたアーカイブ・対応していない形式。**結果として確定させる**
                // ——ここで何もせずに返ると、スピナーが回ったまま残る。
                containedCountsUnreadable = true
            case .cancelled:
                // 打ち切られただけ。**途中まで数えた値も「読めない」も出さない**
                // ——次の読み込みが答えを出す [レビューで発見の方針を踏襲]。
                break
            }
        }
        // 評価を読む [RA-01]。**操作履歴の長さを鍵に含める**——⌘Z / ⇧⌘Z は
        // この View を通らずに DB を書き換えるので、選択と入口だけを鍵に
        // すると取り消した結果が星に反映されない。`operationHistory` は
        // run / undo / redo のいずれでも 1 件増える（`CommandStack.record`）。
        .task(id: RowLoadKey(url: url, libraryID: library?.id,
                                commandRevision: CommandStack.shared.operationHistory.count)) {
            await rating.load(url: url, library: library, services: LibraryServices.shared)
        }
        // タイトルとカバーを読む [RP-10][CV-01]。鍵の考え方は評価と同じ。
        .task(id: RowLoadKey(url: url, libraryID: library?.id,
                                commandRevision: CommandStack.shared.operationHistory.count)) {
            await title.load(url: url, library: library, services: LibraryServices.shared)
        }
        .task(id: RowLoadKey(url: url, libraryID: library?.id,
                                commandRevision: CommandStack.shared.operationHistory.count)) {
            await cover.load(url: url, library: library, services: LibraryServices.shared)
        }
        // ラベルを読む [RL-01]。鍵の考え方は評価と同じ（⌘Z はこの View を
        // 通らずに DB を書き換える）。`labelRevision` も含めるのは、ダイアログ
        // から新しく作ったラベルが一覧に無いため。
        .task(id: LabelLoadKey(url: url, libraryID: library?.id,
                               commandRevision: CommandStack.shared.operationHistory.count,
                               revision: labelRevision)) {
            await labels.load(urls: [url], library: library, services: LibraryServices.shared)
            await protection.load(urls: [url], library: library,
                                  services: LibraryServices.shared)
        }
        // 保管庫の状態を読む [FA-01][DT-11]。鍵の考え方は評価と同じ。
        .task(id: RowLoadKey(url: url, libraryID: library?.id,
                                commandRevision: CommandStack.shared.operationHistory.count)) {
            await vault.load(url: url, library: library, services: LibraryServices.shared)
        }
        // 未整理のヒントを読む [UR3-04]。**鍵には 2 つの合図がどちらも要る**
        // ［code-review の指摘］——ヒントを変えるのは走査と再マッチング
        // （`contentRevision`）だが、この節が出す「以後無視する」[AL-33] を
        // 変えるのは `SetUnresolvedIgnoredCommand`（`operationHistory`）で、
        // 片方だけだと ⌘Z の結果か、足したフォーマットの結果のどちらかが届かない。
        // どちらも単調に増えるので、和にしても後戻りしない
        // （`parentWatch.generation &+ subtreeWatch.generation` と同じ）。
        .task(id: RowLoadKey(url: url, libraryID: library?.id,
                                commandRevision: LibraryServices.shared.contentRevision
                                    &+ CommandStack.shared.operationHistory.count)) {
            await unresolved.load(url: url, library: library, services: LibraryServices.shared)
        }
        .onChange(of: url, initial: true) { _, newValue in
            parentWatch.watch(newValue.deletingLastPathComponent(), scope: .shallow)
        }
        .onChange(of: SubtreeWatchKey(url: url, isDirectory: info?.isNavigableFolder == true), initial: true) { _, key in
            subtreeWatch.watch(key.isDirectory ? key.url : nil, scope: .shallow)
        }
    }

    /// `.task(id:)` は 1 つの値しか取れないため、対象と「変更があった回数」を
    /// 束ねる。2 つの世代番号を足しているのは、どちらが増えても値が変わり
    /// さえすればよいため（差分の内訳は使わない）。
    private struct ReloadKey: Equatable {
        let url: URL
        let generation: Int
    }

    private struct SubtreeWatchKey: Equatable {
        let url: URL
        let isDirectory: Bool
    }

    /// 「選択中の DB 行を読み直す」ための鍵。評価・タイトル・カバーが共有する
    /// ——どれも同じ 1 行を読むので、鍵が食い違うと片方だけ古いまま残る。
    private struct RowLoadKey: Equatable {
        let url: URL
        let libraryID: LibraryID?
        let commandRevision: Int
    }

    private struct LabelLoadKey: Equatable {
        let url: URL
        let libraryID: LibraryID?
        let commandRevision: Int
        let revision: Int
    }

    /// **`nonisolated` は必須。** `resourceValues` は I/O を伴うため呼び出し元は
    /// `FileIO.perform` の中から呼ぶ [NV6-02] が、`View` は `@MainActor` なので
    /// static メソッドも既定では MainActor 隔離のまま——外さないと FileIO の
    /// スレッド上で隔離検査の表明が破れ `dispatch_assert_queue_fail` →
    /// `EXC_BREAKPOINT` で落ちる（`VolumeEjectAction.ejectableVolume` と同じ罠、
    /// 実機で発生）。
    nonisolated private static func loadInfo(for url: URL) -> FileDetailInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ]) else { return nil }
        // **`isDirectory` は実体のまま持ち、パッケージかどうかは別に持つ**
        // [実機検証で発見: `isDirectory` を潰したら、`.app` のサイズが
        // 「0 KB」と表示された——ディレクトリの `fileSize` は `nil` なので、
        // ファイル扱いにした瞬間に `?? 0` が効いてしまう]。
        //
        // 使い分けは呼び出し側で決める:
        //  ・サイズを出すか  → 実体がファイルのときだけ（`isDirectory` を見る）
        //  ・中を数えるか    → フォルダのときだけ（`isNavigableFolder` を見る）
        // パッケージの中を数えないので、写真ライブラリ（`.photoslibrary`）を
        // 選んだだけで TCC の許可ダイアログが出ることも無くなる。
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isArchive = !isDirectory && ArchiveFormat.from(filename: url.lastPathComponent) != nil
        return FileDetailInfo(
            isDirectory: isDirectory,
            isPackage: isPackage,
            isArchive: isArchive,
            size: values.fileSize.map(Int64.init),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            // パッケージは実際の種別で答える（`.app` なら「アプリケーション」）。
            kindDescription: Self.kindDescription(for: url, isDirectory: isDirectory && !isPackage)
        )
    }

    /// `FolderContentView.FolderEntry.kindDescription` と同じロジック。
    /// 専用の共有ヘルパーに切り出すほどの規模ではないため、意図的にここでも
    /// 同じ数行を持つ（`ThumbnailService.identity(of:)` と同じ理由）。
    /// `loadInfo`（nonisolated、FileIO のスレッド上で走る）から呼ばれるため
    /// こちらも nonisolated。
    /// - Parameter isDirectory: **パッケージを除いた**「フォルダか」。
    ///   `.app` を「フォルダ」と答えないよう、呼び出し側で除いてから渡す。
    nonisolated private static func kindDescription(for url: URL, isDirectory: Bool) -> String {
        let locale = AppLanguage.effectiveLocale
        if isDirectory { return String(localized: "kind.folder", locale: locale) }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        guard !ext.isEmpty else { return String(localized: "kind.document", locale: locale) }
        return String(format: String(localized: "kind.extensionFile", locale: locale), ext.uppercased())
    }

    /// [DT-05][DT-06] 遅延読み込み。仕様書は DB キャッシュを前提とするが、
    /// フェーズ1にはまだ DB が無いため、選択のたびに再計算する（キャッシュは
    /// フェーズ2で追加）。フォルダは実サイズも大きくなり得る（C-07: 1 ライブラリ
    /// 1万〜5万ファイル）ため、メインアクタを外れたところで列挙し、ループ内で
    /// 定期的にキャンセルを確認する。
    ///
    /// **`Task.detached` は使わない** [1-14 のレビューで記録した既知の課題を
    /// ここで解消した]。あれは呼び出し元のキャンセルを引き継がないため、
    /// 選択を切り替えても、あるいは監視が変更を知らせて計算をやり直させても、
    /// 古い走査が 5 万件を最後まで数え続けていた。`nonisolated` な async 関数を
    /// 直接 `await` すれば、メインアクタを外れつつキャンセルも伝わる
    /// （`FolderContentView.runSearch` と同じ形）。
    /// - Note: **協調プールではなく専用のスレッド源で走らせる** [NV6-01]。
    ///   `nonisolated` にしただけではメインアクタを外れるだけで、走る先は
    ///   協調スレッドプールのまま。5 万件の走査が応答しない共有で止まると、
    ///   その 1 本がプールのスレッドを 1 本占有し続ける（コア数ぶん溜まれば
    ///   アプリの `async` 処理が全部止まる）。取り消しは `Cancellation` 経由で
    ///   届く。
    /// 中身を数えた結果 [DT-05][DT-06]。
    ///
    /// **「打ち切られた」と「読めなかった」を分ける。** どちらも `nil` にして
    /// いたため、壊れたアーカイブを選ぶとスピナーが永久に回っていた
    /// ［ユーザーが実機で指摘］——前者は次の読み込みが答えを出すので黙って
    /// 待てばよいが、後者はそれ以上何も起きない。
    private enum ContainedCountsResult {
        case counted(ContainedCounts)
        case unreadable
        case cancelled
    }

    nonisolated private static func computeContainedCounts(for url: URL,
                                                           isArchive: Bool) async -> ContainedCountsResult {
        if isArchive {
            return await computeArchiveCounts(url)
        }
        guard let counts = await FileIO.perform({ computeFolderCounts(url) }) else {
            return .cancelled
        }
        return .counted(counts)
    }

    /// 打ち切られたら `nil`。**途中まで数えた値を返さない** — 呼び出し側が
    /// それを確定値として表示してしまうため [レビューで発見]。
    ///
    /// **実体は `DirectoryProbe.containedCounts(at:)` に移した**［2026-08-29］
    /// ——プライバシー保護された場所へ降りないガードを、呼び出し側ではなく
    /// 関数の内側に閉じ込めるため（ここに書いていたときは、同じ穴が三角判定と
    /// この集計の 2 箇所に別々に空いていた）。
    nonisolated private static func computeFolderCounts(_ url: URL) -> ContainedCounts? {
        guard let counts = DirectoryProbe.containedCounts(at: url) else { return nil }
        return ContainedCounts(fileCount: counts.fileCount,
                               folderCount: counts.folderCount,
                               totalSize: counts.totalSize)
    }

    private static func computeArchiveCounts(_ url: URL) async -> ContainedCountsResult {
        guard let backend = ArchiveBackendRegistry.reader(for: url) else { return .unreadable }
        // 取り消しは「読めない」ではない——選択を動かしただけで「読めません」と
        // 出ると、実際には読めるアーカイブを読めないものだと誤解させる。
        guard !Task.isCancelled else { return .cancelled }
        guard let listing = try? await backend.listEntries(url) else {
            return Task.isCancelled ? .cancelled : .unreadable
        }
        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0
        for entry in listing.entries {
            if entry.isDirectory {
                folderCount += 1
            } else if !entry.isSymlink && !entry.isSpecialEntry {
                fileCount += 1
                totalSize += entry.uncompressedSize
            }
        }
        return .counted(ContainedCounts(fileCount: fileCount, folderCount: folderCount,
                                        totalSize: totalSize))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FileDetailInfo {
    /// **実体がディレクトリか。** パッケージ（`.app` など）もここは `true`。
    let isDirectory: Bool
    /// Finder が 1 つの項目として扱うディレクトリ [ユーザー要望]。
    let isPackage: Bool
    let isArchive: Bool
    let size: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let kindDescription: String

    /// 中を数える対象か。**パッケージは数えない**——利用者にとっては 1 つの
    /// 項目で、写真ライブラリのような TCC 保護のパッケージでは、選んだだけで
    /// 許可ダイアログが出ることにもなる。
    var isNavigableFolder: Bool { isDirectory && !isPackage }
}

private struct ContainedCounts {
    let fileCount: Int
    let folderCount: Int
    let totalSize: Int64
}

/// 複数選択時は共通情報のみ [RP-02]。ラベルの一括付与・削除は Phase 2
/// （ラベルドメイン型が無いため）。
private struct MultiItemInspector: View {
    @Environment(\.locale) private var locale
    let urls: [URL]
    /// 表示中のライブラリ [RP-02]。ボリューム経由なら `nil`。
    let library: LibrarySummary?

    /// ラベルの一括付与／削除 [RP-02][RL-01〜RL-07]。
    @State private var labels = LabelEditorModel()
    @State private var protection = ProtectionEditorModel()
    @State private var labelRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                Text(String(format: String(localized: "inspector.itemsSelected", locale: locale), urls.count))
                    .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
                Divider()
                LabeledContent("inspector.totalSize", value: Self.sizeFormatter.string(fromByteCount: Self.totalSize(of: urls)))
                InspectorLabelSection(model: labels) { labelRevision &+= 1 }
                InspectorProtectionSection(model: protection)   // [PR-05]
            }
            .padding(Tokens.spacing.m)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: LoadKey(urls: urls, libraryID: library?.id,
                          commandRevision: CommandStack.shared.operationHistory.count,
                          revision: labelRevision)) {
            await labels.load(urls: urls, library: library, services: LibraryServices.shared)
            await protection.load(urls: urls, library: library,
                                  services: LibraryServices.shared)
        }
    }

    private struct LoadKey: Equatable {
        let urls: [URL]
        let libraryID: LibraryID?
        let commandRevision: Int
        let revision: Int
    }

    /// `FileInfoSheet`（1-9 までの簡易版）と同じ単純化: フォルダは中身を
    /// 再帰的に足し込まず、ファイルのサイズだけを合計する（多数選択時に
    /// 重い再帰列挙を避けるため）。
    private static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  values.isDirectory != true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// フォルダ/アーカイブ/画像ファイルのサムネイル、生成できない場合は Finder
/// アイコンにフォールバックする [IV-01/08、`FileIconProvider` 参照]。
/// `IconGridView.ThumbnailImage` と似た構造だが、表示サイズ・余白の付け方が
/// 異なる（グリッドセルは正方形、こちらは横幅いっぱいの固定高さ）ため、
/// 専用の共有コンポーネントへ切り出すほどの規模ではないと判断し、意図的に
/// 個別実装にしている。
struct InspectorThumbnail: View {
    let url: URL
    let thumbnailsHidden: Bool

    /// `IconGridView.ThumbnailImage.RequestKey` と同じ役割・同じ理由
    /// （非表示への切替で生成を取り消し、再表示で生成し直す [DS-05]）。
    private struct RequestKey: Equatable {
        let url: URL
        let hidden: Bool
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FileIconProvider.shared.icon(for: url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Tokens.spacing.xl)
            }
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .task(id: RequestKey(url: url, hidden: thumbnailsHidden)) {
            image = nil
            guard !thumbnailsHidden else { return } // [DS-06]
            guard let cgImage = await ThumbnailService.shared.thumbnail(for: url, maxPixelSize: 320) else { return }
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}
