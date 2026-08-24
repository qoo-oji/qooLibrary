import Foundation
import QooKit

/// アーカイブ／フォルダの中から、カバーに使うページを選ぶための一覧と読み出し
/// [CV-05][TH-06]。
///
/// ## なぜ専用の型があるか
/// `CoverImageSourceResolver` は「**先頭 1 枚**」だけを解決する。こちらは
/// 「利用者に選ばせるための一覧」なので、目的も費用の性質も違う——同じ型に
/// 混ぜると、サムネイル生成の経路が誤って全エントリを読む形へ育ちうる。
///
/// ## 読み出しは 1 件ずつ直列に行う
/// 一覧のセルは可視範囲だけが生成される（`LazyVGrid`）ので、素直に書くと
/// 十数件が同時に読み出しを始める。zip は中央ディレクトリから目的の位置へ
/// シークできるので実測でも安いが（下記）、**solid 圧縮の 7z / RAR は
/// N 件目を取り出すのに 1〜N 件目を復号する**ため、同時に走らせると費用が
/// 積の形で効いてくる。1 本に絞り、**後から要求されたものを先に処理する**
/// （＝いま画面に見えているもの）[TH-02]。
///
/// ## 実測（zip、この開発機）
/// 250KB × 100 エントリ（圧縮しづらい中身、25MB）で
/// `listEntries` 13.3 ms、`readEntry` × 100 が **56.6 ms（0.57 ms/件）**。
/// libarchive は seekable な zip を先頭から読み直さないので、素直に 1 件ずつ
/// 読んでよい。**単色 PNG で測ると 700B まで縮んで走査の費用が出ない**ので、
/// 測り直すときは圧縮しづらい中身を使うこと。
public actor ArchiveCoverPicker {
    /// 候補 1 件。
    public struct Candidate: Sendable, Hashable, Identifiable {
        /// アーカイブ内のパス名、またはフォルダ直下のファイル名。
        public let name: String
        public let byteSize: Int64
        public var id: String { name }

        public init(name: String, byteSize: Int64) {
            self.name = name
            self.byteSize = byteSize
        }
    }

    private enum Container {
        case archive(any ArchiveReading, ArchiveListing)
        case folder([URL])
    }

    private let url: URL
    private let maxBytes: Int
    private var container: Container?
    private var loadFailed = false

    /// 直列化のための待ち行列。**LIFO**——いま見えているものを先に出す [TH-02]。
    private var waiting: [(Candidate, CheckedContinuation<Data?, Never>)] = []
    private var isWorking = false

    public init(url: URL, maxBytes: Int = AppLimits.Thumbnail.defaultMaxEntryReadBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// カバーに使える候補を自然順で返す [CV-05]。
    ///
    /// - Parameter limit: 上限。**一覧そのものは安い**（`listEntries` は中央
    ///   ディレクトリを読むだけ）が、際限なく並べても選べないため区切る。
    public func candidates(limit: Int = AppLimits.Thumbnail.defaultCoverPickerCandidates)
        async -> [Candidate]
    {
        switch await loadContainer() {
        case .archive(_, let listing):
            let images = listing.entries.filter {
                !$0.isDirectory && !$0.isSymlink && !$0.isSpecialEntry
                    && PreviewableFileKind.isImageFilename($0.pathname)
            }
            return images
                .sorted { $0.pathname.localizedStandardCompare($1.pathname) == .orderedAscending }
                .prefix(limit)
                .map { Candidate(name: $0.pathname, byteSize: $0.uncompressedSize) }
        case .folder(let children):
            let images = children.filter { child in
                guard let isDirectory = try? child.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory, !isDirectory else { return false }
                return PreviewableFileKind.isImageFilename(child.lastPathComponent)
            }
            return images
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
                .prefix(limit)
                .map { child in
                    let size = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return Candidate(name: child.lastPathComponent, byteSize: Int64(size))
                }
        case nil:
            return []
        }
    }

    /// 候補 1 件の生バイト列。読めなければ `nil`。
    public func data(for candidate: Candidate) async -> Data? {
        await withCheckedContinuation { continuation in
            waiting.append((candidate, continuation))
            startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard !isWorking else { return }
        isWorking = true
        Task { await drain() }
    }

    private func drain() async {
        // `popLast()` で LIFO。待っている間に届いた要求が先に処理される。
        while let (candidate, continuation) = waiting.popLast() {
            continuation.resume(returning: await read(candidate))
        }
        isWorking = false
    }

    private func read(_ candidate: Candidate) async -> Data? {
        switch await loadContainer() {
        case .archive(let backend, let listing):
            guard let entry = listing.entries.first(where: { $0.pathname == candidate.name })
            else { return nil }
            return try? await backend.readEntry(url, entry: entry,
                                                encoding: listing.detectedEncoding,
                                                maxBytes: maxBytes)
        case .folder(let children):
            guard let child = children.first(where: { $0.lastPathComponent == candidate.name })
            else { return nil }
            return await CoverImageSourceResolver.firstImageData(for: child,
                                                                 maxEntryReadBytes: maxBytes)
        case nil:
            return nil
        }
    }

    private func loadContainer() async -> Container? {
        if let container { return container }
        guard !loadFailed else { return nil }
        let loaded: Container?
        switch PreviewableFileKind.of(url) {
        case .folder:
            let folder = url
            let children = await FileIO.perform {
                (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
            }
            loaded = .folder(children)
        case .archive, .epub:
            // **EPUB もここを通る。** カバーを選ぶ場面では「読み順の先頭」
            // ではなく「中の画像を全部見せて選ばせる」ほうが目的に合う
            // （`CoverImageSourceResolver` が EPUB だけ専用経路を持つのは
            // 自動解決の話）。
            if let backend = ArchiveBackendRegistry.reader(for: url),
               let listing = try? await backend.listEntries(url) {
                loaded = .archive(backend, listing)
            } else {
                loaded = nil
            }
        case .image, .video, .pdf, .other:
            loaded = nil
        }
        if let loaded {
            container = loaded
        } else {
            loadFailed = true
        }
        return loaded
    }
}
