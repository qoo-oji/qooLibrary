//
//  スキャンエンジン [10.3][FO-20][SY-01〜SY-12][SE3-01〜SE3-08]。
//
//  **差分イベントに反応するのではなく、実ファイルの状態と DB を突き合わせて
//  収束させる** [FO-20][SY-12]。同じイベントを 2 回処理しても結果が変わらない。
//
//  リポジトリは `QooKit` のプロトコル越しに受け取る——`QooInfrastructure` は
//  `QooPersistence` に依存できない [A-01]。実装の注入は `QooApplication` が行う。
//
import Foundation
import QooKit

public struct ScanSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var reidentified = 0        // [ID-04]
    public var orphaned = 0            // [ID-06]
    public var unresolvedNames = 0     // [AL-31]
    /// 巻数の判断待ち [EM-26]。`ComicInfo.xml` の `Number` と `Volume` が
    /// 食い違ったファイルの件数。**スキャンは止めず、完了後にまとめて聞く** [EM-31]。
    public var volumeConflicts = 0
    public var bookFoldersDetected = 0
    /// 1 冊扱いが解除されたフォルダ [IF-05]。**孤立ではない**——通知の対象。
    public var bookFoldersReleased: [FileID] = []
    /// この走査で見た「場所」の数 [SY-03]。差分が全体列挙へ落ちていないかを
    /// テストと診断ログで確かめるために持つ。
    public var scannedUnits = 0
    public var skipped = false         // オフライン等で走らなかった [SB-05]
    public var cancelled = false

    public var total: Int { added + updated }

    /// 走らなかったことを表す値。エンジンが組み立てられていない場面で使う。
    public static let notRun = ScanSummary(skipped: true)

    public init(skipped: Bool = false) {
        self.skipped = skipped
    }
}

/// 走査の進捗 1 報ぶん [RG3-32]。
///
/// **報告はファイル単位。** 以前は 500 件のバッチ境界 [SE3-05] でしか名前を
/// 報告しなかったため、埋め込みメタデータの読み取り等で 1 バッチが長引くと
/// 表示が凍って見えた［ユーザー指摘: 処理が止まっているように見えて不安になる］。
/// 間引きは表示側（`ProgressThrottle`）に任せ、エンジンは間引かない。
public struct ScanProgress: Sendable {
    public enum Phase: Sendable {
        /// 実ファイルの列挙中。総数はまだ分からない（`total == 0`）。
        case enumerating
        /// DB との突き合わせ・メタデータ読み取り・パース中。
        case processing
    }

    public var phase: Phase
    /// 処理済み（列挙中は見つけた）件数。
    ///
    /// **メタデータ読み取りの間は進まない**——読み取りとパースは同じ
    /// ファイル群を 2 度なめるので、両方で数えると件数が行き来して見える。
    /// その間は `currentName` のほうが動き続ける（名前か件数のどちらかが
    /// 動いていればよい [RG3-32]）。
    public var processed: Int
    /// 総数。列挙が終わるまでは 0（不定進捗）。
    public var total: Int
    public var currentName: String

    public init(phase: Phase, processed: Int, total: Int, currentName: String) {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.currentName = currentName
    }
}

public actor ScanEngine {
    public enum Mode: Sendable {
        /// FSEvents 差分 [SY-03]。渡されたパスの親フォルダだけを見る。
        case incremental(libraryID: LibraryID, paths: [String])
        case full(libraryID: LibraryID)                                    // [SY-05][AT-02]
        case folder(libraryID: LibraryID, relativePath: String, recursive: Bool)  // [SY-06]

        var libraryID: LibraryID {
            switch self {
            case .incremental(let id, _), .full(let id), .folder(let id, _, _): return id
            }
        }
    }

    public struct Dependencies: Sendable {
        public let libraries: any LibraryRepository
        public let files: any ManagedFileRepository
        public let labels: any LabelRepository
        public let parser: any FilenameParsing
        public let bookmarks: any BookmarkResolving
        /// 埋め込みメタデータの読み取り [EM-09]。テストからフェイクを刺せる。
        public let metadata: any EmbeddedMetadataReading
        /// クラウドから追い出された実体かどうか [EM-62]。
        ///
        /// **テストから差し替えられるようにしておく**（`ThumbnailService` と
        /// 同じ形）——実体を追い出した状態を一時ディレクトリでは作れない。
        public let isDataless: @Sendable (URL) -> Bool

        public init(libraries: any LibraryRepository, files: any ManagedFileRepository,
                    labels: any LabelRepository, parser: any FilenameParsing = FilenameParser(),
                    bookmarks: any BookmarkResolving = SecurityScopedBookmarkResolver(),
                    metadata: any EmbeddedMetadataReading = EmbeddedMetadataReader(),
                    isDataless: @escaping @Sendable (URL) -> Bool = {
                        CloudMaterialization.isDataless($0)
                    }) {
            self.libraries = libraries
            self.files = files
            self.labels = labels
            self.parser = parser
            self.bookmarks = bookmarks
            self.metadata = metadata
            self.isDataless = isDataless
        }
    }

    let deps: Dependencies
    let enumerator = LibraryEnumerator()
    /// 走査した根 URL の解決結果。ライブラリごとに 1 回で足りる。
    var rootCache: [LibraryID: URL] = [:]

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// 走査してライブラリと DB を収束させる。
    ///
    /// **同じライブラリの走査は同時に 1 本しか走らない。** `actor` は `await` を
    /// 挟むたびに再入するので、それだけでは直列にならない——フル走査と差分走査が
    /// 重なると、**一方の列挙で観測していない行をもう一方が孤立にする**（自分が
    /// 見ていないものを「無くなった」と読む）ため、ラベルと評価を失う [R-01]。
    /// 手動の再スキャンと自動の追随が同時に起こりうる以上、ここで塞ぐ。
    ///
    /// - Parameter onProgress: ファイル単位の進捗 [RG3-32]。**間引かずに呼ぶ**
    ///   ので、UI へ流す側が `ProgressThrottle` で間引くこと。一覧への反映は
    ///   従来どおりバッチ境界 [ST-10][ST-12]。
    public func scan(_ mode: Mode,
                     root: URL? = nil,
                     onProgress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary
    {
        guard await acquire(mode.libraryID) else {
            var summary = ScanSummary()
            summary.cancelled = true
            return summary
        }
        defer { release(mode.libraryID) }
        return try await performScan(mode, root: root, onProgress: onProgress)
    }

    // MARK: - ライブラリ単位の排他

    private var running: Set<LibraryID> = []
    private var waiters: [LibraryID: [CheckedContinuation<Void, Never>]] = [:]

    /// 順番を待つ。**取り消されたら獲得しない**——`ThumbnailService` の
    /// スロット待ちで踏んだのと同じ罠で、起こされた継続がそのまま獲得すると
    /// 「誰も解放しない占有」が残る。
    private func acquire(_ id: LibraryID) async -> Bool {
        while running.contains(id) {
            if Task.isCancelled { return false }
            await withCheckedContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
            if Task.isCancelled { return false }
        }
        running.insert(id)
        return true
    }

    private func release(_ id: LibraryID) {
        running.remove(id)
        guard let queued = waiters.removeValue(forKey: id) else { return }
        for continuation in queued { continuation.resume() }
    }

    private func performScan(_ mode: Mode,
                             root: URL?,
                             onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanSummary
    {
        var summary = ScanSummary()
        guard let library = try await deps.libraries.library(id: mode.libraryID) else {
            summary.skipped = true
            return summary
        }
        // **オフライン時は孤立判定を一切行わない** [SB-05][ID-08][R-01]。
        // ここで止めるのが唯一の砦——外部ボリュームを抜いただけでラベル紐づけを
        // 一括で失う事故を防ぐ。
        guard library.isOnline else {
            summary.skipped = true
            Log.scan.info("スキャンを見送る（オフライン）: \(Log.redactable(library.displayName))")
            return summary
        }

        let rootURL = try root ?? resolveRoot(library)

        // **根が本当にこのライブラリのものかを確かめる。**
        //
        // 上の `isOnline` は「唯一の砦」と書いてあるが、その値を更新する経路が
        // 無い間は常に真で素通りする。しかも `resolveRoot` は保存済みのパス
        // 文字列から URL を組み立てるだけで、実体の有無もボリュームの同一性も
        // 見ていない。したがって砦は実質「列挙が throw すること」に依存して
        // いた——偶然に頼った安全である。
        //
        // 危ないのは**同じマウントポイントに別のボリュームが載る**場合
        // （macOS は `/Volumes/<名前>` を使い回す）。列挙は成功し、中身は
        // 別物なので、**観測されなかった＝ライブラリ全件が孤立**になる。
        // 外部ボリュームを抜き差ししただけでラベル紐づけを一括で失う事故
        // [R-01][SB-05][ID-08] そのもの。
        //
        // ボリューム識別子で突き合わせればどちらの形も塞げる。取れない
        // （ネットワーク等）場合は突き合わせを諦めて先へ進む——判定できない
        // ことを理由に正当なスキャンを断るほうが害が大きい [NV3-01 と同じ判断]。
        let rootIsSound = await FileIO.perform { () -> Bool in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            guard let current = VolumeIdentity.identifier(for: rootURL) else { return true }
            return current == library.volumeUUID
        }
        guard rootIsSound else {
            summary.skipped = true
            Log.scan.info("スキャンを見送る（根が無いか別のボリューム）: \(Log.redactable(library.displayName)) — \(Log.path(rootURL))")
            return summary
        }
        guard let settings = try await deps.libraries.settingsSnapshot(libraryID: library.id) else {
            summary.skipped = true
            return summary
        }

        // ① 走査する場所を決める [SY-03]。
        //
        // **差分は「変更のあった場所だけ」を見る。** 以前はここが `.folder`
        // のときしか絞られておらず、`.incremental` でもライブラリ全体を
        // 列挙していた——ファイルが 1 つ変わるたびに 5 万件の走査が走る形
        // だったので、`LibraryWatcher` を結線する前にここを塞いだ。
        let plan = await resolveScanUnits(mode, rootURL: rootURL)
        summary.scannedUnits = plan.count

        // ② 実ファイルの列挙 [SE3-01]。ブロッキング I/O なので `FileIO` へ逃がす [NV6-01]。
        //
        // **列挙できなかった単位は孤立の判定から外す**［F2 が最悪の失敗様式］。
        // 「読めなかった」を「無くなった」と読み替えると、権限やネットワークの
        // 一時的な不調でラベルと評価を失う [R-01]。
        let collector = SnapshotCollector()
        let enumerator = self.enumerator
        var enumerated: [ScanUnit] = []
        var firstFailure: (any Error)?
        for unit in plan {
            if Cancellation.isRequested || Task.isCancelled { summary.cancelled = true; break }
            guard case .enumerate(let subPath, let recursive) = unit else {
                enumerated.append(unit)          // `.vanished` は列挙しない
                continue
            }
            let options = LibraryEnumerator.Options(
                targetExtensions: settings.targetExtensions,
                imageExtensions: settings.imageExtensions.isEmpty
                    ? BookFolderDetector.defaultImageExtensions : settings.imageExtensions,
                subPath: subPath, recursive: recursive)
            do {
                try await FileIO.perform {
                    try enumerator.enumerate(root: rootURL, libraryID: library.id,
                                             volumeUUID: library.volumeUUID, options: options) {
                        let count = collector.append($0)
                        // 列挙中も名前と件数を動かし続ける [RG3-32]。総数は
                        // まだ分からないので 0（表示は不定進捗のまま）。
                        onProgress?(ScanProgress(phase: .enumerating, processed: count,
                                                 total: 0, currentName: $0.filename))
                    }
                }
                enumerated.append(unit)
            } catch {
                if firstFailure == nil { firstFailure = error }
                Log.scan.warning("""
                    走査単位を列挙できない（孤立の判定から外す）: \
                    \(Log.redactable(library.displayName)) — \(Log.redactable(subPath))
                    """)
            }
        }
        // **1 つも列挙できなかったなら失敗として投げる。** 単位が 1 つだけの
        // フルスキャン・フォルダスキャンでは従来どおりの振る舞いになる。
        if let firstFailure, enumerated.isEmpty { throw firstFailure }
        let snapshots = collector.take()
        if Task.isCancelled { summary.cancelled = true; return summary }
        summary.bookFoldersDetected = snapshots.count { $0.isBookFolder }

        // ③ DB と突き合わせて収束させる [FO-20]。
        //    保存は 500 件のバッチ境界で行う [SE3-05][ST-13]。
        var seen = Set<FileID>()
        var processed = 0
        let total = snapshots.count
        for chunk in snapshots.chunked(into: AppLimits.Watch.scanBatchSize) {
            if Task.isCancelled { summary.cancelled = true; break }
            let outcome = try await reconcile(chunk, settings: settings, rootURL: rootURL,
                                              progressBase: processed, progressTotal: total,
                                              onProgress: onProgress)
            seen.formUnion(outcome.seen)
            summary.added += outcome.added
            summary.updated += outcome.updated
            summary.reidentified += outcome.reidentified
            summary.unresolvedNames += outcome.unresolvedNames
            summary.volumeConflicts += outcome.volumeConflicts
            processed += chunk.count
        }

        // ④ 観測されなかったレコードを孤立にする [ID-06]。
        //
        // **実際に見た範囲でだけ行う。** 差分スキャンでも行うようになった
        // ——以前は `.incremental` を丸ごと除外していたため、外部で削除された
        // ファイルが DB に `active` のまま残り続けていた。範囲を単位ごとに
        // 絞ってあるので「見ていない範囲を消す」ことにはならない。
        if !summary.cancelled {
            for unit in enumerated {
                let scope: FileQuery.Scope
                switch unit {
                case .enumerate(let path, let recursive):
                    scope = path.isEmpty && recursive
                        ? .library : .folder(path: path, recursive: recursive)
                case .vanished(let path):
                    // 実体が確かに無いと分かっている場所。配下をまとめて孤立にする。
                    scope = .folder(path: path, recursive: true)
                }
                // 観測されなかったレコードを、実体の有無で振り分ける。
                //
                // **ブックフォルダが 1 冊扱いを解除された場合は孤立にしてはならない**
                // [IF-05]。実体はまだそこにあり、ラベル紐づけも維持する。孤立にすると
                // 「ファイルが消えた」という別の意味になってしまう。
                let unseen = try await deps.files.unseen(
                    libraryID: library.id, scope: scope, seen: seen)
                var stillOrphaned: [FileID] = []
                for row in unseen {
                    let url = rootURL.appendingPathComponent(row.relativePath)
                    let exists = await FileIO.perform { () -> Bool in
                        var isDirectory: ObjCBool = false
                        let found = FileManager.default.fileExists(atPath: url.path,
                                                                   isDirectory: &isDirectory)
                        return found && isDirectory.boolValue
                    }
                    if row.isBookFolder, exists {
                        try await deps.files.releaseBookFolder(row.id)       // [IF-05]
                        summary.bookFoldersReleased.append(row.id)
                    } else {
                        stillOrphaned.append(row.id)
                    }
                }
                if !stillOrphaned.isEmpty {
                    try await deps.files.setState(.orphaned, ids: stillOrphaned)   // [ID-06]
                }
                summary.orphaned += stillOrphaned.count
            }
        }

        Log.scan.info("""
            スキャン完了 \(Log.redactable(library.displayName)): \
            追加 \(summary.added) / 更新 \(summary.updated) / 孤立 \(summary.orphaned) \
            / 未解決 \(summary.unresolvedNames)
            """)
        return summary
    }

    // MARK: - 走査範囲 [SY-03]

    /// このモードでどこを見るかを決める。
    ///
    /// 差分の場合だけ実体を問い合わせる（ディレクトリかファイルか、消えて
    /// いるか）。**ブロッキング I/O なので `FileIO` へ逃がす** [NV6-02]。
    func resolveScanUnits(_ mode: Mode, rootURL: URL) async -> [ScanUnit] {
        switch mode {
        case .full:
            return [.enumerate(relativePath: "", recursive: true)]
        case .folder(_, let path, let recursive):
            return [.enumerate(relativePath: path, recursive: recursive)]
        case .incremental(_, let paths):
            guard !paths.isEmpty else {
                // 変更のあった場所が分からない差分要求はフルスキャンと同じ [SY-04]。
                return [.enumerate(relativePath: "", recursive: true)]
            }
            let planned = await FileIO.perform {
                // **ディスク上の綴りに揃えてから使う** [実測]。
                //
                // 孤立の判定は SQLite の `LIKE` でパスの接頭辞を照合するので、
                // **正規化や大小文字が 1 文字違うだけで 1 件も一致しない**。
                // `contentsOfDirectory` は濁点を NFD（`U+30BF U+3099`）で返す
                // 一方、アプリが自分で作ったパス（利用者が打った名前）は NFC
                // （`U+30C0`）のことがある——照合が黙って空振りし、削除が
                // いつまでも反映されない、という気づきにくい形になる。
                //
                // `realpath(3)` は**ディスク上の綴りそのもの**を返す（正規化も
                // 大小文字も。`aBC` で引いても `Abc` が返る）ので、これを通せば
                // 列挙が書き込む `relativePath` と必ず揃う。
                let canonicalRoot = Self.canonicalPath(rootURL.path) ?? rootURL.path
                let canonical = paths.map {
                    Self.canonicalRelativePath($0, rootURL: rootURL,
                                               canonicalRoot: canonicalRoot)
                }
                return ScanUnitPlanner.units(changedPaths: canonical, kind: { relative in
                    Self.pathKind(rootURL.appendingPathComponent(relative))
                })
            }
            guard let planned else {
                Log.scan.debug("差分の範囲を絞れないのでフルスキャンへ落とす（\(paths.count) 件の変更）")
                return [.enumerate(relativePath: "", recursive: true)]   // [SY-04]
            }
            return planned
        }
    }

    /// `realpath(3)` の薄い包み。存在しなければ `nil`。
    ///
    /// - Note: `FileIO.perform` の中からのみ呼ぶこと [NV6-02]。
    static func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        // `String(cString: [CChar])` は非推奨。NUL で切ってから復号する。
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 相対パスをディスク上の綴りに揃える。
    ///
    /// **存在する最深の祖先まで解決して、残りを継ぎ足す。** 素の `realpath` は
    /// 対象が消えていると丸ごと失敗するので、それでは削除の経路
    /// （＝いちばん綴りを揃えたい場面）で毎回諦めることになる。
    /// `RegisteredFolderStore` が登録パスの正規化で使っているのと同じ形。
    ///
    /// ## なぜ綴りを揃えるのか [実測]
    /// 孤立の判定は SQLite の `LIKE` でパスの接頭辞を照合するので、
    /// **正規化や大小文字が 1 文字違うだけで 1 件も一致しない**。
    /// `contentsOfDirectory` は濁点を NFD（`U+30BF U+3099`）で返す一方、
    /// アプリが組み立てたパスは NFC（`U+30C0`）のことがある——照合が黙って
    /// 空振りし、削除がいつまでも反映されない、という気づきにくい形になる。
    /// `realpath(3)` は**ディスク上の綴りそのもの**を返す（`aBC` で引いても
    /// `Abc` が返る）ので、これを通せば列挙が書き込む `relativePath` と揃う。
    ///
    /// ## 残る限界
    /// **消えた末尾の綴りだけは分からない**——その情報はファイルと一緒に
    /// 消えている。実際には食い違わない（FSEvents はディスク上の綴りを返し、
    /// アプリ自身の削除も一覧から選ばれた URL＝`contentsOfDirectory` 由来）。
    /// 万一食い違っても**孤立が起きないだけ**で、別のファイルを誤って孤立に
    /// することはない。次のフルスキャン [SY-05] が拾う。
    static func canonicalRelativePath(_ relative: String, rootURL: URL,
                                      canonicalRoot: String) -> String {
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        var components = relative.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var tail: [String] = []
        while !components.isEmpty {
            let candidate = rootURL.appendingPathComponent(components.joined(separator: "/")).path
            if let canonical = canonicalPath(candidate), canonical.hasPrefix(prefix) {
                let head = String(canonical.dropFirst(prefix.count))
                return (([head] + tail)).joined(separator: "/")
            }
            tail.insert(components.removeLast(), at: 0)
        }
        return tail.joined(separator: "/")
    }

    /// パスの実体。**`lstat` を使う**——シンボリックリンクは走査の対象外
    /// [SL-03] なので、リンク先まで辿って「ディレクトリ」と答えてはいけない。
    ///
    /// - Note: `FileIO.perform` の中からのみ呼ぶこと [NV6-02]。
    static func pathKind(_ url: URL) -> ScanUnitPlanner.PathKind {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .file
        }
        // `ENOENT`/`ENOTDIR` は「確かに無い」。それ以外（権限・無応答）は
        // **判定できない**として扱い、推測で孤立にしない。
        switch errno {
        case ENOENT, ENOTDIR: return .absent
        default: return .unknown
        }
    }

    // MARK: - 突き合わせ

    struct ChunkOutcome {
        var seen: Set<FileID> = []
        var added = 0
        var updated = 0
        var reidentified = 0
        var unresolvedNames = 0
        var volumeConflicts = 0
    }

    func reconcile(_ snapshots: [FileSnapshot],
                   settings: LibrarySettingsSnapshot,
                   rootURL: URL,
                   progressBase: Int = 0,
                   progressTotal: Int = 0,
                   onProgress: (@Sendable (ScanProgress) -> Void)? = nil)
        async throws -> ChunkOutcome
    {
        var outcome = ChunkOutcome()

        // 既存かどうかを先に見る（`upsertBatch` は「あれば更新」なので区別が付かない）。
        var existing: [FileIdentity: FileID] = [:]
        for snapshot in snapshots {
            if let id = try await deps.files.find(identity: snapshot.identity) {
                existing[snapshot.identity] = id
            }
        }

        // **この走査で inode により引けた行**。名前やパスの一致（より弱い証拠）で
        // これを横取りしてはならない [ID3-08]——移動と新規作成が同時に起きると、
        // 移動先で正しく引けている行を、元の場所にできた別のファイルが
        // パスの一致で奪い、評価が移動していないほうへ付いてしまう。
        var claimed = Set(existing.values)

        // 同一性で引けなかったものは再照合を試みる [ID-03][ID-04]。
        for snapshot in snapshots where existing[snapshot.identity] == nil {
            let candidates = try await deps.files.findCandidates(for: snapshot)
            // **まだ生きているファイルを担っている行は候補から外す** [ID3-08]。
            //
            // `findCandidates` は名前とパスだけで引く（リポジトリは実体を
            // 知らない）ので、**別のフォルダにある無関係な同名ファイルの行**も
            // 返す。確度の並びでは「同名＋同サイズ」(`.nameAndSize`) が
            // 「同じ場所・サイズ違い」(`.pathOnly`) より上なので、同名の
            // ファイルを作り直しただけで**別のフォルダの生きている行が
            // 先頭に来る**——そのまま引き継ぐと、その行が担っていたファイルは
            // 記録を失い、評価・手動ラベル・手動タイトルごと消える。
            //
            // 引き継いでよいのは「実体を失った行」だけである。候補の記録上の
            // 場所に**いま別のファイルが居る**なら、その行はまだ現役なので
            // 触ってはならない。差し替え（同じ場所に別の実体）と移動
            // （元の場所は空）はどちらもこの検査を通る。
            let free = try await unclaimedCandidates(candidates, for: snapshot,
                                                     rootURL: rootURL, claimed: claimed)
            guard let best = free.first else { continue }
            // inode を更新して既存レコードとみなす。ラベルは維持される [ID-04]。
            //
            // **確認は挟まない** [ID-09〜ID-15 撤回、§19.8]——差し替えは
            // ガード付き（上の [ID3-08]。生きている行・inode で引けた行は
            // 候補に入らない）で常に自動で引き継ぐ。以前ここにあった
            // 3 段階ポリシー [ID-13] は既定の `sameName`（＝全確度を自動）
            // へ固定して撤去した。
            try await deps.files.reidentify(best.fileID, to: snapshot.identity)
            existing[snapshot.identity] = best.fileID
            claimed.insert(best.fileID)
            outcome.reidentified += 1
        }

        let ids = try await deps.files.upsertBatch(snapshots)

        for (offset, id) in ids.enumerated() {
            outcome.seen.insert(id)
            if existing[snapshots[offset].identity] == nil { outcome.added += 1 }
            else { outcome.updated += 1 }
        }

        // ③ 埋め込みメタデータ [EM-09]。**パースより先に読む**——
        //    パース結果へフィールド単位で上書きするため [EM-04]。
        //    件数はここでは進めない（`ScanProgress.processed` の注記）——
        //    容器を開くのが走査で最も時間のかかる局面なので、代わりに
        //    **名前を 1 件ずつ**動かす [RG3-32]。
        let metadata = try await readMetadata(snapshots, ids: ids,
                                              rootURL: rootURL, settings: settings,
                                              onFileRead: { name in
            onProgress?(ScanProgress(phase: .processing, processed: progressBase,
                                     total: progressTotal, currentName: name))
        })

        // ④ パースとラベル付与 [RC-01]。
        var unresolved: [UnresolvedObservation] = []
        var resolvedIDs: [FileID] = []
        for (offset, id) in ids.enumerated() {
            let snapshot = snapshots[offset]
            // ファイル単位で件数と名前を進める [RG3-32]。間引きは表示側。
            onProgress?(ScanProgress(phase: .processing,
                                     processed: progressBase + offset + 1,
                                     total: progressTotal,
                                     currentName: snapshot.filename))
            let embedded = metadata[id]?.metadata
            let isUnresolved = try await applyResolution(
                relativePath: snapshot.relativePath,
                nameWithoutExtension: snapshot.nameWithoutExtension,
                isBookFolder: snapshot.isBookFolder,
                embedded: embedded, to: id, settings: settings)

            if isUnresolved {
                outcome.unresolvedNames += 1                     // [AL-31]
                unresolved.append(UnresolvedObservation(fileID: id,
                                                        filename: snapshot.filename))
            } else {
                resolvedIDs.append(id)
            }
            if embedded?.volumeConflict != nil {
                outcome.volumeConflicts += 1                     // [EM-26]
            }
        }
        // ⑤ 未解決の記録 [AL-31]。**解決したものの削除も同じ呼び出しで行う**
        //    ——収束型 [FO-20] なので、観測した集合をそのまま渡せば、
        //    フォーマットを足して解決したものは自動的に一覧から消える。
        try await deps.files.syncUnresolved(unresolved: unresolved, resolved: resolvedIDs,
                                            libraryID: settings.libraryID, now: Date())
        return outcome
    }

    /// 候補のうち、**まだ生きているファイルを担っていない**ものだけ [ID3-08]。
    ///
    /// 候補の記録上の場所を 1 度の `FileIO` でまとめて調べる——再照合は
    /// 稀な経路だが、候補ごとに往復するとネットワーク上のライブラリで効く。
    ///
    /// 「居るのが自分自身」なら現役ではない（同じ場所での差し替え [ID-03]③a）
    /// ので通す。`lstat` を使うのは `pathKind` と揃えるため——シンボリック
    /// リンクは走査の対象外 [SL-03] なので、リンク先まで辿って「使用中」と
    /// 答えてはいけない。
    func unclaimedCandidates(_ candidates: [ReidentificationCandidate],
                             for snapshot: FileSnapshot,
                             rootURL: URL,
                             claimed: Set<FileID>) async throws -> [ReidentificationCandidate]
    {
        // この走査で inode により引けた行は、より弱い証拠で奪わない。
        let candidates = candidates.filter { !claimed.contains($0.fileID) }
        guard !candidates.isEmpty else { return [] }
        let paths = candidates.map { rootURL.appendingPathComponent($0.relativePath).path }
        let occupants: [UInt64?] = await FileIO.perform {
            paths.map { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                return UInt64(info.st_ino)
            }
        }
        return candidates.enumerated().compactMap { offset, candidate in
            guard let inode = occupants[offset] else { return candidate }  // 実体を失った行
            return inode == snapshot.identity.inode ? candidate : nil      // 居るのは自分自身
        }
    }

    // MARK: - パース結果の書き戻し

    /// パースして DB へ書き戻し、**未解決かどうか**を返す。
    ///
    /// **走査と再マッチング [AL-34] の両方がここを通る。** 別々に書くと
    /// 「走査では未解決なのに再マッチングでは解決する（またはその逆）」という、
    /// 画面からは理由の読み取れない食い違いが起こる——実際、`isUnresolved` は
    /// 埋め込みメタデータの有無まで見る [EM-03] ので、片方だけ直すと簡単にずれる。
    func applyResolution(relativePath: String, nameWithoutExtension: String,
                         isBookFolder: Bool, embedded: EmbeddedMetadata?,
                         to id: FileID, settings: LibrarySettingsSnapshot) async throws -> Bool
    {
        let parsed = FolderLabelResolver.resolve(
            relativePath: relativePath,
            nameWithoutExtension: nameWithoutExtension,
            settings: settings, parser: deps.parser,
            purpose: .libraryScan,
            endsWithBookFolder: isBookFolder)
        let resolved = EmbeddedMetadataMerge.apply(embedded, to: parsed, settings: settings)

        try await deps.files.applyParsedFields(
            ParsedFileFields(
                matchedFormatID: resolved.matchedFormatID ?? UUID(),
                title: resolved.title, seriesName: resolved.seriesName,
                volume: resolved.volume, authorName: resolved.authorName,
                labelValues: resolved.labels,
                libraryTypeMismatch: resolved.libraryTypeMismatch,
                spans: []),
            to: id)
        try await applyLabels(resolved.labels, to: id, settings: settings)
        return EmbeddedMetadataMerge.isUnresolved(parsed, metadata: embedded)
    }

    // MARK: - 再マッチング [AL-34]

    /// 未解決ファイルを、現在の設定でパースし直す [AL-34][UR-04]。
    ///
    /// **実ファイルを列挙し直さない。** DB に載っている相対パスとファイル名から
    /// パースし直し、埋め込みメタデータは読み取り済みのキャッシュ [EM-07] を使う
    /// ——フォーマットを 1 本足すたびにライブラリ全体を歩き直すのは、
    /// ネットワーク上のライブラリでは費用が釣り合わない（§9.9 の実測で
    /// 5 万件が 10 分）。実体を見直したいときは通常の再スキャンを使う。
    ///
    /// **無視したもの [AL-33] も対象にする。** 解決すれば行ごと消えるので
    /// 無視の意味が無くなり、解決しなければ無視のまま残る——どちらでも
    /// 利用者の意思に反しない。
    ///
    /// 走査と同じライブラリ単位の排他を取るので、自動追随の走査と重なっても
    /// 一方が他方の書いた行を読み違えることはない。
    public func rematchUnresolved(libraryID: LibraryID) async throws -> RematchOutcome {
        guard await acquire(libraryID) else {
            return RematchOutcome(attempted: 0, resolved: 0, cancelled: true)
        }
        defer { release(libraryID) }

        guard let settings = try await deps.libraries.settingsSnapshot(libraryID: libraryID)
        else { return RematchOutcome(attempted: 0, resolved: 0) }

        let files = try await deps.files.unresolvedFiles(libraryID: libraryID,
                                                         includeIgnored: true)
        guard !files.isEmpty else { return RematchOutcome(attempted: 0, resolved: 0) }

        let cache = try await deps.files.embeddedMetadataCache(ids: files.map(\.id))
        var stillUnresolved: [UnresolvedObservation] = []
        var resolvedIDs: [FileID] = []
        var cancelled = false

        for file in files {
            if Task.isCancelled { cancelled = true; break }
            let isUnresolved = try await applyResolution(
                relativePath: file.row.relativePath,
                nameWithoutExtension: file.row.nameWithoutExtension,
                isBookFolder: file.row.isBookFolder,
                embedded: cache[file.id]?.metadata, to: file.id, settings: settings)
            if isUnresolved {
                stillUnresolved.append(UnresolvedObservation(fileID: file.id,
                                                             filename: file.row.filename))
            } else {
                resolvedIDs.append(file.id)
            }
        }

        // **打ち切っても、そこまでの結果は保存する。** 収束型なので、
        // 次に走らせれば続きから片付く。
        try await deps.files.syncUnresolved(unresolved: stillUnresolved,
                                            resolved: resolvedIDs,
                                            libraryID: libraryID, now: Date())
        return RematchOutcome(attempted: resolvedIDs.count + stillUnresolved.count,
                              resolved: resolvedIDs.count, cancelled: cancelled)
    }

    // MARK: - 埋め込みメタデータ [EM-07][EM-09][SE3-20〜SE3-25]

    /// このバッチのメタデータを揃える。**印が一致するものは開かない** [EM-07]。
    ///
    /// 読む必要があるものだけを**上限つき並行**で読む [SE3-20]——I/O 待ちが
    /// 支配的なので、並行にすると実時間がそのぶん縮む。上限を設けるのは、
    /// ネットワーク共有へ一度に大量の要求を投げるとかえって遅くなるため。
    func readMetadata(_ snapshots: [FileSnapshot], ids: [FileID],
                      rootURL: URL, settings: LibrarySettingsSnapshot,
                      onFileRead: (@Sendable (String) -> Void)? = nil)
        async throws -> [FileID: EmbeddedMetadataCacheEntry]
    {
        guard settings.readsEmbeddedMetadata else { return [:] }   // [EM-06]

        let cached = try await deps.files.embeddedMetadataCache(ids: ids)
        var resolved: [FileID: EmbeddedMetadataCacheEntry] = [:]
        var pending: [PendingRead] = []

        for (offset, id) in ids.enumerated() where offset < snapshots.count {
            let snapshot = snapshots[offset]
            let kind = PreviewableFileKind.of(filename: snapshot.filename,
                                              isDirectory: snapshot.isBookFolder)
            guard kind.canCarryEmbeddedMetadata else { continue }   // 開くだけ無駄
            let stamp = EmbeddedMetadataCacheEntry.stamp(modifiedAt: snapshot.modifiedAt,
                                                         fileSize: snapshot.fileSize)
            if let hit = cached[id], hit.stamp == stamp {
                resolved[id] = hit                                  // 開かない [EM-07]
                continue
            }
            pending.append(PendingRead(
                id: id, url: rootURL.appendingPathComponent(snapshot.relativePath),
                kind: kind, stamp: stamp))
        }
        guard !pending.isEmpty else { return resolved }

        let reader = deps.metadata
        let isDataless = deps.isDataless
        let source = settings.comicInfoVolumeSource
        let limit = max(1, AppLimits.Metadata.maxConcurrentReads)
        var fresh: [FileID: EmbeddedMetadataCacheEntry] = [:]

        await withTaskGroup(of: (FileID, EmbeddedMetadataCacheEntry?).self) { group in
            var next = 0
            func submit() {
                guard next < pending.count else { return }
                let item = pending[next]
                next += 1
                group.addTask {
                    // クラウドから追い出された実体は読まない [EM-62]——読むと
                    // ダウンロードが走り、頼んでもいない蔵書全体の実体化が始まる。
                    if await FileIO.perform({ isDataless(item.url) }) {
                        return (item.id, nil)
                    }
                    let metadata = await reader.read(item.url, kind: item.kind,
                                                     volumeSource: source)
                    return (item.id, EmbeddedMetadataCacheEntry(stamp: item.stamp,
                                                                metadata: metadata))
                }
            }
            for _ in 0..<min(limit, pending.count) { submit() }
            var names: [FileID: String] = [:]
            for item in pending { names[item.id] = item.url.lastPathComponent }
            while let (id, entry) = await group.next() {
                if let entry { fresh[id] = entry }
                // 容器を 1 つ読み終えるたびに名前を報告する [RG3-32]。
                if let name = names[id] { onFileRead?(name) }
                if Task.isCancelled { group.cancelAll(); break }
                submit()
            }
        }

        // **読めなかったときも印は書く** [SE3-25]。「読んだが無かった」と
        // 「まだ読んでいない」を区別しないと、メタデータを持たないファイルを
        // 毎回開き直すことになる（同人誌ライブラリでは全件がそれに当たる）。
        if !fresh.isEmpty {
            try await deps.files.saveEmbeddedMetadata(fresh)
        }
        return resolved.merging(fresh) { _, new in new }
    }

    struct PendingRead: Sendable {
        let id: FileID
        let url: URL
        let kind: PreviewableFileKind
        let stamp: String
    }

    /// 自動ラベルを付け直す [RC-01][RC-04]。
    /// 手動・手動除外には触れない（`replaceAutoLabels` が守る）。
    func applyLabels(_ values: [Int: [String]], to fileID: FileID,
                     settings: LibrarySettingsSnapshot) async throws {
        guard !values.isEmpty else {
            try await deps.labels.replaceAutoLabels(fileID: fileID, labelIDs: [])
            return
        }
        var labelIDs: Set<LabelID> = []
        for (groupIndex, names) in values {
            guard let group = try await deps.labels.group(libraryID: settings.libraryID,
                                                          index: groupIndex) else { continue }
            for name in names where !name.isEmpty {
                labelIDs.insert(try await deps.labels.ensureLabel(groupID: group.id, name: name))
            }
        }
        try await deps.labels.replaceAutoLabels(fileID: fileID, labelIDs: labelIDs)
    }

    // MARK: - 内部

    func resolveRoot(_ library: LibrarySummary) throws -> URL {
        if let cached = rootCache[library.id] { return cached }
        let url = URL(fileURLWithPath: library.resolvedPath)
        rootCache[library.id] = url
        return url
    }
}

/// 列挙結果を `FileIO` の逃がし先（別スレッド）から受け取る箱。
/// クロージャが `@Sendable` なので、素の配列を捕捉して書き換えられない。
final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FileSnapshot] = []

    /// - Returns: 追加後の件数（列挙中の進捗表示 [RG3-32] に使う）。
    @discardableResult
    func append(_ snapshot: FileSnapshot) -> Int {
        lock.lock(); defer { lock.unlock() }
        items.append(snapshot)
        return items.count
    }

    func take() -> [FileSnapshot] {
        lock.lock(); defer { items = []; lock.unlock() }
        return items
    }
}

extension Array {
    /// `n` 件ずつに区切る。保存のバッチ境界に使う [SE3-05][ST-13]。
    func chunked(into n: Int) -> [[Element]] {
        guard n > 0 else { return [self] }
        return stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
