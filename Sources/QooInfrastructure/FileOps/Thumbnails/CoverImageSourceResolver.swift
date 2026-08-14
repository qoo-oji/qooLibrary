import Foundation
import QooKit

/// 「この項目のカバーとして使う画像 1 枚の生バイト列」を解決する
/// [9.6 節 `resolveCover` の③、IV-01]。
///
/// 仕様書の `resolveCover` は ①ユーザー指定 → ②サイドカー → ③先頭画像 の
/// 3 段階だが、①②は SwiftData（`Library`/`ManagedFile.coverImageSource`）を
/// 前提とするフェーズ 2 の機能。フェーズ 1 では③だけを担う
/// [`ThumbnailService`/`CoverImageCache` と同じスコープ]。
///
/// **`ThumbnailService` の private なヘルパーだったものを独立させた**
/// [1-14 Quick Look 連携で切り出し]。Quick Look の独自カバープレビュー
/// （`QuickLookCoverStore`、QL-03/QL-08）が同じ「中の先頭画像」を必要とし、
/// 2 箇所に同じ解決順序を持つと片方だけ直される事故が起きるため。
///
/// 実ファイルの**読み取り**しか行わない（`FileManager` の変更系 API は
/// 使わない）ため B-10 の対象ではないが、`ThumbnailService` と一体で
/// 使われるためこのディレクトリに置いている。
public enum CoverImageSourceResolver {
    /// フォルダなら配下の自然順で先頭の画像ファイル、アーカイブならエントリの
    /// 自然順で先頭の画像エントリ、EPUB なら spine（読み順）の先頭ページ、
    /// 画像ファイル自身ならその内容をそのまま返す。取り出せなければ `nil`
    /// （呼び出し側が既定アイコン等へフォールバックする [IM-04]）。
    ///
    /// - Parameter maxEntryReadBytes: アーカイブ内 1 エントリの読み込み上限
    ///   [IM-02][EX-32]。Quick Look 用の読み込みにも同じ上限を適用する
    ///   [IM-05][QL-10]。
    public static func firstImageData(
        for url: URL,
        maxEntryReadBytes: Int = AppLimits.Thumbnail.defaultMaxEntryReadBytes
    ) async -> Data? {
        switch PreviewableFileKind.of(url) {
        case .folder:
            return firstImageDataInFolder(url)
        case .image:
            return try? Data(contentsOf: url)
        case .epub:
            // EPUB は zip コンテナだが「自然順で先頭の画像」ではなく spine
            // （読み順）の先頭ページを取る必要があるため、汎用アーカイブ向けの
            // `firstImageDataInArchive`（自然順ソート）とは別の専用経路にする
            // [`EpubCoverResolver` のコメント参照]。
            return await EpubCoverResolver.firstPageImageData(for: url, maxBytes: maxEntryReadBytes)
        case .archive:
            return try? await firstImageDataInArchive(url, maxEntryReadBytes: maxEntryReadBytes)
        case .video, .pdf, .other:
            // 動画・PDF は画像データを取り出すのではなく専用のレンダラを通す
            // （`VideoThumbnailLoading`/`PDFThumbnailLoading`）。判断は
            // 呼び出し側（`ThumbnailService`）が行う。
            return nil
        }
    }

    private static func firstImageDataInFolder(_ folder: URL) -> Data? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let imageChildren = children.filter { PreviewableFileKind.isImageFilename($0.lastPathComponent) }
        let sorted = imageChildren.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard let firstImage = sorted.first else { return nil }
        return try? Data(contentsOf: firstImage)
    }

    private static func firstImageDataInArchive(_ url: URL, maxEntryReadBytes: Int) async throws -> Data? {
        guard let backend = ArchiveBackendRegistry.reader(for: url) else { return nil }
        let listing = try await backend.listEntries(url)
        let imageEntries = listing.entries.filter {
            !$0.isDirectory && !$0.isSymlink && !$0.isSpecialEntry
                && PreviewableFileKind.isImageFilename($0.pathname)
        }
        let sorted = imageEntries.sorted {
            $0.pathname.localizedStandardCompare($1.pathname) == .orderedAscending
        }
        guard let firstImageEntry = sorted.first else { return nil }
        return try await backend.readEntry(
            url, entry: firstImageEntry, encoding: listing.detectedEncoding, maxBytes: maxEntryReadBytes
        )
    }
}
