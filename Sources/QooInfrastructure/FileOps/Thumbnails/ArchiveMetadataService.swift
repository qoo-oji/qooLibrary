//
//  遅延メタデータ [09章 §9.8][DT-05][DT-06][DU-21][DU-22][MD-01〜MD-03]。
//
//  ページ数（画像ファイル数）と先頭画像の解像度は、**容器を開かないと
//  分からない**。比較ビュー [DU-20] はこれを並べて見せるためにあるので、
//  避けては通れない——代わりに ①要求されたときだけ数える ②結果を DB へ
//  キャッシュする [MD-02] ③同時に開く数を絞る [MD-03] の 3 つで費用を抑える。
//
//  **費用はファイルサイズではなくエントリ数に比例する** [§9.9 の実測]。
//  zip は中央ディレクトリを読むので大きさに引きずられないが、7z の圧縮ありは
//  1 エントリ取り出すのに 4.96 ms かかる。ネットワーク上なら桁がもう 1 つ増える。
//
import CoreGraphics
import Foundation
import QooKit

/// 容器を開いて分かる値。
public struct ArchiveMetadata: Sendable, Hashable {
    /// 中の項目数（画像以外も含む）。
    public let entryCount: Int
    /// ページ数＝画像の数 [DU-21]。
    public let imageCount: Int
    /// 直下のサブフォルダ数 [DT-06]。アーカイブでは中のディレクトリ項目。
    public let subfolderCount: Int
    /// 先頭画像の解像度 [DU-21]。取り出せなければ `nil`。
    public let firstImageSize: CGSize?

    public init(entryCount: Int, imageCount: Int, subfolderCount: Int,
                firstImageSize: CGSize?) {
        self.entryCount = entryCount
        self.imageCount = imageCount
        self.subfolderCount = subfolderCount
        self.firstImageSize = firstImageSize
    }
}

/// 容器を開いて数える [MD-01〜MD-03]。
///
/// **`actor` にして同時に開く数を絞る** [MD-03][PF-11]。比較ビューは組の
/// 全メンバーを一度に要求するので、素直に並行させると 1 組で数十の容器を
/// 同時に開くことになる——solid 圧縮の 7z / RAR では 1 件ごとに
/// 前のエントリまで復号し直すため、費用が積の形で効く。
public actor ArchiveMetadataService {
    public static let shared = ArchiveMetadataService()

    private let images: any ImageLoading
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    public init(images: any ImageLoading = DefaultImageLoader(),
                maxConcurrent: Int = AppLimits.Thumbnail.defaultMaxConcurrent) {
        self.images = images
        self.maxConcurrent = maxConcurrent
    }

    /// 1 件ぶんの値を数える。取り消された・読めなかったときは `nil`。
    ///
    /// **数えられなかったことと「0 件」を区別する** [MD-01]——`nil` を返し、
    /// 呼び出し側はプレースホルダのまま置く。0 を返すと「中身が空の本」に見え、
    /// 一括選択規則 [DU-25] が**中身のあるほうを捨てかねない**。
    public func metadata(for url: URL) async -> ArchiveMetadata? {
        guard await acquireSlot() else { return nil }
        defer { releaseSlot() }
        guard !Cancellation.isRequested else { return nil }
        let loader = images
        switch PreviewableFileKind.of(url) {
        case .folder:
            return await FileIO.perform { Self.computeFolder(url, images: loader) }
        case .pdf:
            return await FileIO.perform { Self.computePDF(url) }
        case .archive, .epub:
            // **ここは `FileIO.perform` で包まない**——バックエンドが自分で
            // 逃がしている（`LibarchiveBackend.listEntries` 参照）。
            return await Self.computeArchive(url, images: loader)
        case .image, .video, .other:
            return await FileIO.perform { Self.computeSingleItem(url, images: loader) }
        }
    }

    // MARK: - 数える本体

    /// 単一の実体はページの概念を持たない。**`nil` ではなく 1 件**として返す
    /// ——数え損ねたのではなく、数えた結果である。
    static func computeSingleItem(_ url: URL, images: any ImageLoading) -> ArchiveMetadata {
        let isImage = PreviewableFileKind.of(url) == .image
        let data = isImage ? try? Data(contentsOf: url) : nil
        return ArchiveMetadata(entryCount: 1, imageCount: isImage ? 1 : 0,
                               subfolderCount: 0,
                               firstImageSize: data.flatMap { images.imageSize(from: $0) })
    }

    static func computeFolder(_ url: URL, images: any ImageLoading) -> ArchiveMetadata? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return nil }
        var entries = 0, imageFiles = 0, folders = 0
        var firstImage: String?
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        where !name.hasPrefix(".") {
            entries += 1
            var isDir: ObjCBool = false
            let path = url.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders += 1; continue }
            if PreviewableFileKind.isImageFilename(name) {
                imageFiles += 1
                if firstImage == nil { firstImage = path }
            }
        }
        let size = firstImage
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { images.imageSize(from: $0) }
        return ArchiveMetadata(entryCount: entries, imageCount: imageFiles,
                               subfolderCount: folders, firstImageSize: size)
    }

    static func computeArchive(_ url: URL, images: any ImageLoading) async -> ArchiveMetadata? {
        guard let reader = ArchiveBackendRegistry.reader(for: url),
              let listing = try? await reader.listEntries(url) else { return nil }
        let imageEntries = listing.entries
            .filter { !$0.isDirectory && PreviewableFileKind.isImageFilename($0.pathname) }
            .sorted { $0.pathname.localizedStandardCompare($1.pathname) == .orderedAscending }
        // **解像度のためだけに 1 エントリ取り出す。** 一覧だけなら zip の
        // 中央ディレクトリで済むが、寸法は実データを見ないと分からない。
        var size: CGSize?
        if let first = imageEntries.first,
           let data = try? await reader.readEntry(
               url, entry: first, encoding: listing.detectedEncoding,
               maxBytes: AppLimits.Thumbnail.defaultMaxEntryReadBytes) {
            size = images.imageSize(from: data)
        }
        return ArchiveMetadata(
            entryCount: listing.entries.count,
            imageCount: imageEntries.count,
            subfolderCount: listing.entries.filter(\.isDirectory).count,
            firstImageSize: size)
    }

    static func computePDF(_ url: URL) -> ArchiveMetadata? {
        // **ネットワーク上では mmap を避ける** [NV6-08]——切断中のフォルトは
        // `SIGBUS` で、Swift の `try` では捕まえられずアプリごと死ぬ。
        guard let document = CoreGraphicsPDFThumbnailLoader.openDocument(at: url) else { return nil }
        let pages = document.numberOfPages
        var size: CGSize?
        if pages > 0, let page = document.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            size = CGSize(width: box.width, height: box.height)
        }
        return ArchiveMetadata(entryCount: pages, imageCount: pages,
                               subfolderCount: 0, firstImageSize: size)
    }

    // MARK: - 同時実行数 [MD-03][PF-11]

    /// `ThumbnailService.acquireSlot` と同じ形。取り消されたら `false`。
    ///
    /// **待ち行列には識別子を持たせる。** 先頭を取り出す形にすると、
    /// 取り消されたタスクが**別の（生きている）要求を身代わりに解放**し、
    /// そちらが読めるはずのアーカイブに対して「—」を出す（`ThumbnailService`
    /// が UUID を持たせているのはまさにこのため）。
    private func acquireSlot() async -> Bool {
        // **`Task.isCancelled` は使えない** [NV6-01]——借りたスレッドの上では
        // 常に false を返し、検査が黙って効かなくなる。
        if Cancellation.isRequested { return false }
        if active < maxConcurrent { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.releaseWaiter(id) }
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            active -= 1
        }
    }

    /// 取り消された**その要求だけ**を待ち行列から外す。
    private func releaseWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
