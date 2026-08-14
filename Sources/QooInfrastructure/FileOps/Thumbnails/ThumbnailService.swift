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
    private let pdfThumbnailLoader: PDFThumbnailLoading

    // PF-11: 同時実行数を制限したタスクキュー。実際の重い処理（アーカイブ
    // 読み込み・デコード）はアクター分離の外（`Task.detached`）で行うが、
    // 「同時に何本まで」の管理はここに集約する。
    private var activeCount = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    public init(
        maxConcurrent: Int = AppLimits.Thumbnail.defaultMaxConcurrent,
        cache: CoverImageCache = DefaultCoverImageCache.shared,
        imageLoader: ImageLoading = DefaultImageLoader(),
        videoThumbnailLoader: VideoThumbnailLoading = QLVideoThumbnailLoader(),
        pdfThumbnailLoader: PDFThumbnailLoading = CoreGraphicsPDFThumbnailLoader()
    ) {
        self.maxConcurrent = maxConcurrent
        self.cache = cache
        self.imageLoader = imageLoader
        self.videoThumbnailLoader = videoThumbnailLoader
        self.pdfThumbnailLoader = pdfThumbnailLoader
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
    ///
    /// `url` 自身が PDF・EPUB の場合もそれぞれ専用の経路で生成する
    /// ［ユーザー要望: qooLibrary は qooViewer のフロントエンドであり、
    /// qooViewer が対応する形式は qooLibrary 側でも網羅する必要がある］。
    /// PDF は `PDFThumbnailLoading`（CoreGraphics でページ1を直接描画）、
    /// EPUB は `EpubCoverResolver`（zip コンテナとして読み、spine の先頭
    /// ページの画像データを取り出して以降は通常の画像デコード経路に合流）。
    public func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let identity = try? Self.identity(of: url) else { return nil }
        if let cached = cache.loadCachedImage(for: identity) {
            return cached
        }

        await acquireSlot()
        defer { releaseSlot() }
        // [フェーズ1完了時のリソースリーク監査で追加] `IconGridView` の
        // `.task(id:)` はセルが画面外へスクロールされると自動的にキャンセル
        // される。スロット待ちの間にキャンセルされたリクエストが、順番が
        // 回ってきた後もそのまま重いデコード処理へ進んでしまわないよう、
        // スロット取得直後にここで打ち切る。
        if Task.isCancelled { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let generated: CGImage?
        if !isDirectory.boolValue, Self.isVideoFilename(url.lastPathComponent) {
            generated = await videoThumbnailLoader.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
        } else if !isDirectory.boolValue, Self.isPDFFilename(url.lastPathComponent) {
            generated = await pdfThumbnailLoader.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
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
        // [フェーズ1完了時のリソースリーク監査で追加] 素の `withCheckedContinuation`
        // はタスクのキャンセルを観測しないため、`waiters` に積まれたまま
        // どのリクエストからも `releaseSlot()` が呼ばれなければ継続が永久に
        // 迷子になり得た（実機での再現経路: アイコン表示を高速スクロールし、
        // 同時実行数の上限を超えて `waiters` に積まれた直後にスクロールし
        // 続けてそのセルが二度と表示されない場合）。`withTaskCancellationHandler`
        // でキャンセルを検知し、まだ順番待ちであれば即座に解放する。
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.resumeWaiterIfStillWaiting(id) }
        }
        activeCount += 1
    }

    /// キャンセルされたリクエストの継続が `waiters` に残っていれば取り除いて
    /// 即座に再開させる。既に順番が回ってきて resume 済みなら何もしない
    /// （`withTaskCancellationHandler` の `onCancel` と通常の `releaseSlot()`
    /// が同じ継続を二重に resume してしまわないための安全策）。
    private func resumeWaiterIfStillWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    private func releaseSlot() {
        activeCount -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
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
        if isEpubFilename(url.lastPathComponent) {
            // EPUB は zip コンテナだが「自然順で先頭の画像」ではなく spine
            // （読み順）の先頭ページを取る必要があるため、`firstImageDataInArchive`
            // （汎用アーカイブ向け、自然順ソート）とは別の専用経路にする
            // [`EpubCoverResolver` のコメント参照]。
            return await EpubCoverResolver.firstPageImageData(
                for: url, maxBytes: AppLimits.Thumbnail.defaultMaxEntryReadBytes
            )
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

    private static func isPDFFilename(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .pdf)
    }

    /// EPUB は `UTType` に共通の静的定数（`.pdf`/`.movie` 等と違い）が
    /// 標準搭載されていないため、拡張子の直接比較にしている
    /// （`org.idpf.epub-container` という UTI 自体は macOS 標準搭載だが、
    /// `UTType(filenameExtension:)` 経由の解決に不必要に依存しないため）。
    private static func isEpubFilename(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "epub"
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
