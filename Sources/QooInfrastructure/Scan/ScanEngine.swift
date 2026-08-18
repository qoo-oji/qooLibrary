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
    public var candidatesForReview = 0 // [ID-05]
    public var unresolvedNames = 0     // [AL-31]
    public var bookFoldersDetected = 0
    /// 1 冊扱いが解除されたフォルダ [IF-05]。**孤立ではない**——通知の対象。
    public var bookFoldersReleased: [FileID] = []
    public var skipped = false         // オフライン等で走らなかった [SB-05]
    public var cancelled = false

    public var total: Int { added + updated }
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

        public init(libraries: any LibraryRepository, files: any ManagedFileRepository,
                    labels: any LabelRepository, parser: any FilenameParsing = FilenameParser(),
                    bookmarks: any BookmarkResolving = SecurityScopedBookmarkResolver()) {
            self.libraries = libraries
            self.files = files
            self.labels = labels
            self.parser = parser
            self.bookmarks = bookmarks
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
    /// - Parameter onProgress: `(処理済み件数, 直近のファイル名)`。
    ///   件数は逐次、一覧の反映はバッチ境界 [ST-10][ST-12]。
    public func scan(_ mode: Mode,
                     root: URL? = nil,
                     onProgress: (@Sendable (Int, String) -> Void)? = nil) async throws -> ScanSummary
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
        guard let settings = try await deps.libraries.settingsSnapshot(libraryID: library.id) else {
            summary.skipped = true
            return summary
        }

        let options = LibraryEnumerator.Options(
            targetExtensions: settings.targetExtensions,
            imageExtensions: settings.imageExtensions.isEmpty
                ? BookFolderDetector.defaultImageExtensions : settings.imageExtensions,
            subPath: {
                if case .folder(_, let path, _) = mode { return path }
                return ""
            }(),
            recursive: {
                if case .folder(_, _, let recursive) = mode { return recursive }
                return true
            }())

        // ① 実ファイルの列挙 [SE3-01]。ブロッキング I/O なので `FileIO` へ逃がす [NV6-01]。
        let collector = SnapshotCollector()
        let enumerator = self.enumerator
        try await FileIO.perform {
            try enumerator.enumerate(root: rootURL, libraryID: library.id,
                                     volumeUUID: library.volumeUUID, options: options) {
                collector.append($0)
            }
        }
        let snapshots = collector.take()
        if Task.isCancelled { summary.cancelled = true; return summary }
        summary.bookFoldersDetected = snapshots.count { $0.isBookFolder }

        // ② DB と突き合わせて収束させる [FO-20]。
        //    保存は 500 件のバッチ境界で行う [SE3-05][ST-13]。
        var seen = Set<FileID>()
        var processed = 0
        for chunk in snapshots.chunked(into: AppLimits.Watch.scanBatchSize) {
            if Task.isCancelled { summary.cancelled = true; break }
            let outcome = try await reconcile(chunk, settings: settings)
            seen.formUnion(outcome.seen)
            summary.added += outcome.added
            summary.updated += outcome.updated
            summary.reidentified += outcome.reidentified
            summary.candidatesForReview += outcome.candidatesForReview
            summary.unresolvedNames += outcome.unresolvedNames
            processed += chunk.count
            onProgress?(processed, chunk.last?.filename ?? "")
        }

        // ③ 観測されなかったレコードを孤立にする [ID-06]。
        //    差分スキャンでは行わない——見ていない範囲を消してしまうため。
        if !summary.cancelled, case .incremental = mode {} else if !summary.cancelled {
            let scope: FileQuery.Scope = {
                if case .folder(_, let path, let recursive) = mode {
                    return .folder(path: path, recursive: recursive)
                }
                return .library
            }()
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
            summary.orphaned = stillOrphaned.count
        }

        Log.scan.info("""
            スキャン完了 \(Log.redactable(library.displayName)): \
            追加 \(summary.added) / 更新 \(summary.updated) / 孤立 \(summary.orphaned) \
            / 未解決 \(summary.unresolvedNames)
            """)
        return summary
    }

    // MARK: - 突き合わせ

    struct ChunkOutcome {
        var seen: Set<FileID> = []
        var added = 0
        var updated = 0
        var reidentified = 0
        var candidatesForReview = 0
        var unresolvedNames = 0
    }

    func reconcile(_ snapshots: [FileSnapshot],
                   settings: LibrarySettingsSnapshot) async throws -> ChunkOutcome {
        var outcome = ChunkOutcome()

        // 既存かどうかを先に見る（`upsertBatch` は「あれば更新」なので区別が付かない）。
        var existing: [FileIdentity: FileID] = [:]
        for snapshot in snapshots {
            if let id = try await deps.files.find(identity: snapshot.identity) {
                existing[snapshot.identity] = id
            }
        }

        // 同一性で引けなかったものは再照合を試みる [ID-03][ID-04]。
        for snapshot in snapshots where existing[snapshot.identity] == nil {
            let candidates = try await deps.files.findCandidates(for: snapshot)
            guard let best = candidates.first else { continue }
            switch best.confidence {
            case .pathAndSize, .nameAndSize:
                // inode を更新して既存レコードとみなす。ラベルは維持される [ID-04]。
                try await deps.files.reidentify(best.fileID, to: snapshot.identity)
                existing[snapshot.identity] = best.fileID
                outcome.reidentified += 1
            case .nameOnly:
                // **自動では紐づけない** [ID-05][ID3-03]。新規として作り、
                // 孤立ファイル一覧に「候補あり」として出す。
                outcome.candidatesForReview += 1
            }
        }

        let ids = try await deps.files.upsertBatch(snapshots)
        for (offset, id) in ids.enumerated() {
            outcome.seen.insert(id)
            if existing[snapshots[offset].identity] == nil { outcome.added += 1 }
            else { outcome.updated += 1 }
        }

        // ③ パースとラベル付与 [RC-01]。
        for (offset, id) in ids.enumerated() {
            let snapshot = snapshots[offset]
            let resolved = FolderLabelResolver.resolve(
                relativePath: snapshot.relativePath,
                nameWithoutExtension: snapshot.nameWithoutExtension,
                settings: settings, parser: deps.parser,
                purpose: .libraryScan,
                endsWithBookFolder: snapshot.isBookFolder)

            if resolved.matchedFormatID == nil, resolved.labels.isEmpty {
                outcome.unresolvedNames += 1                     // [AL-31]
            }
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
        }
        return outcome
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

    func append(_ snapshot: FileSnapshot) {
        lock.lock(); items.append(snapshot); lock.unlock()
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
