import CoreGraphics
import Foundation
import QooKit
import UniformTypeIdentifiers

/// フォルダ表示モードでの先頭画像サムネイル生成 [9.6 節、IV-01][IV-08][IV-09]。
///
/// 仕様書の `resolveCover` は ①ユーザー指定 → ②サイドカー → ③先頭画像、の
/// 3段階だが、①②は SwiftData（`Library`/`ManagedFile.coverImageSource`）が
/// 前提の Phase 2 機能。フェーズ1にはまだ DB もライブラリ登録も無いため、
/// このサービスは③（フォルダ・アーカイブの先頭画像）だけを担う
/// [1-9 のスコープ、`CoverImageCache.swift` のコメントと同じ理由]。
public actor ThumbnailService {
    public static let shared = ThumbnailService()

    private let maxConcurrent: Int
    private let cache: CoverImageCache
    private let imageLoader: ImageLoading
    private let videoThumbnailLoader: VideoThumbnailLoading

    // PF-11: 同時実行数を制限したタスクキュー。実際の重い処理（アーカイブ
    // 読み込み・デコード）はアクター分離の外（`Task.detached`）で行うが、
    // 「同時に何本まで」の管理はここに集約する。
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        maxConcurrent: Int = AppLimits.Thumbnail.defaultMaxConcurrent,
        cache: CoverImageCache = DefaultCoverImageCache.shared,
        imageLoader: ImageLoading = DefaultImageLoader(),
        videoThumbnailLoader: VideoThumbnailLoading = QLVideoThumbnailLoader()
    ) {
        self.maxConcurrent = maxConcurrent
        self.cache = cache
        self.imageLoader = imageLoader
        self.videoThumbnailLoader = videoThumbnailLoader
    }

    /// `url` はフォルダ、または対応アーカイブ形式のファイル。フォルダ表示モード
    /// でのアイコン表示 [IV-01] から呼ばれる想定。キャッシュ済みなら即座に
    /// 返し、無ければ生成してキャッシュする。生成できない場合は `nil`
    /// （呼び出し側が既定アイコンにフォールバックする [IM-04]）。
    ///
    /// `url` 自身が動画ファイルの場合は `VideoThumbnailLoading`
    /// （`QLThumbnailGenerator` 経由）で生成する［ユーザー要望、動画ライブラリ
    /// としての利用を見据えた拡張］。フォルダ／アーカイブ内の「先頭の動画」を
    /// カバーとして使う対応は対象外（IV-01 が要求する「先頭画像」の範囲を
    /// 超えるため、必要になれば別途検討する）。
    public func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let identity = try? Self.identity(of: url) else { return nil }
        if let cached = cache.loadCachedImage(for: identity) {
            return cached
        }

        await acquireSlot()
        defer { releaseSlot() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let generated: CGImage?
        if !isDirectory.boolValue, Self.isVideoFilename(url.lastPathComponent) {
            generated = await videoThumbnailLoader.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
        } else {
            guard let data = await Self.resolveFirstImageData(for: url) else { return nil }
            let loader = imageLoader
            let task = Task.detached(priority: .utility) { () -> CGImage in
                try loader.makeThumbnail(from: data, maxPixelSize: maxPixelSize)
            }
            generated = try? await task.value
        }

        guard let generated else { return nil }
        _ = try? cache.store(generated, for: identity)
        return generated
    }

    /// 手動コマンド「サムネイルを再生成」用 [MX 一覧]。指定したファイルの
    /// キャッシュを消すだけで、実際の再生成は次回の `thumbnail(for:)` 呼び出し
    /// 時に自然に行われる。
    public func invalidate(_ urls: [URL]) async {
        for url in urls {
            guard let identity = try? Self.identity(of: url) else { continue }
            try? FileManager.default.removeItem(at: cache.url(for: identity))
        }
    }

    // MARK: - 同時実行数の制限 [PF-11]

    private func acquireSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - 先頭画像の解決 [IV-01]

    /// フォルダなら配下の自然順先頭の画像ファイル、アーカイブならエントリの
    /// 自然順先頭の画像エントリ、画像ファイル自身ならその内容をそのまま読む
    /// （IV-01 は「圧縮ファイルやフォルダも」とあるが、画像ファイル自体の
    /// プレビューは実装しない理由が無いため自然な拡張として含めている）。
    private static func resolveFirstImageData(for url: URL) async -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            return firstImageDataInFolder(url)
        }
        if isImageFilename(url.lastPathComponent) {
            return try? Data(contentsOf: url)
        }
        return try? await firstImageDataInArchive(url)
    }

    private static func firstImageDataInFolder(_ folder: URL) -> Data? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let imageChildren = children.filter { isImageFilename($0.lastPathComponent) }
        let sorted = imageChildren.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let firstImage = sorted.first else { return nil }
        return try? Data(contentsOf: firstImage)
    }

    private static func firstImageDataInArchive(_ url: URL) async throws -> Data? {
        guard let backend = ArchiveBackendRegistry.reader(for: url) else { return nil }
        let listing = try await backend.listEntries(url)
        let imageEntries = listing.entries.filter {
            !$0.isDirectory && !$0.isSymlink && !$0.isSpecialEntry && isImageFilename($0.pathname)
        }
        let sorted = imageEntries.sorted { $0.pathname.localizedStandardCompare($1.pathname) == .orderedAscending }
        guard let firstImageEntry = sorted.first else { return nil }
        return try await backend.readEntry(
            url, entry: firstImageEntry, encoding: listing.detectedEncoding,
            maxBytes: AppLimits.Thumbnail.defaultMaxEntryReadBytes
        )
    }

    private static func isImageFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private static func isVideoFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    /// `FileOperationService.identity(of:)` と同じ計算 [ID-01]。専用の共有
    /// ヘルパーに切り出すほどの規模ではないため、意図的にここでも同じ数行を
    /// 持つ（`FileIdentity` 自体は `QooKit` の値型で、計算方法だけがこの2箇所
    /// にある）。
    private static func identity(of url: URL) throws -> FileIdentity {
        let volumeUUID = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? ""
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileIdentity(volumeUUID: volumeUUID, inode: UInt64(statInfo.st_ino))
    }
}
