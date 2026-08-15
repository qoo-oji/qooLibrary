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

    /// フォルダ**直下**の、それ自体がサムネイルを持てるファイルを自然順で
    /// 最大 `limit` 件返す［ユーザー要望: アイコン表示でフォルダの中身を
    /// 複数枚見せたい］。
    ///
    /// ここが返すのは **URL だけ**で、画像の取り出しは行わない。各 URL の
    /// サムネイル化は `ThumbnailService.thumbnail(for:)` にそのまま任せる
    /// ——そうすると `.cbz` は中の先頭画像、`.pdf` は 1 ページ目、動画は
    /// `QLThumbnailGenerator`、と**既存の経路がそのまま再利用でき**、しかも
    /// 生成結果はその子自身の `FileIdentity` でキャッシュされるので、
    /// **同じファイルを単体で表示したときのセルとキャッシュを共有できる**。
    ///
    /// **サブフォルダは含めない**［ユーザー指定: 「直下に」］。含めると
    /// 再帰的な走査になり、階層の深いライブラリでコストが読めなくなる。
    ///
    /// 動画も対象に含めている［設計判断］。ユーザーの列挙（zip/cbz/rar/cbr/
    /// 7z/cb7/pdf/epub/画像）には無いが、動画は既に単体ではサムネイルが出る
    /// ため、除くと「フォルダを開くと絵が出るのに、フォルダ自体は素のアイコン」
    /// という説明のつかない差になる。外したい場合はこの `case .video` を
    /// 落とすだけでよい。
    public static func coverSourceChildren(
        for folder: URL,
        limit: Int = AppLimits.Thumbnail.defaultFolderCoverCount
    ) -> [URL] {
        guard limit > 0 else { return [] }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates = children.filter { child in
            // ディレクトリ判定は列挙時に取得済みの値を使い、`PreviewableFileKind.of(_:)`
            // が行う 1 件ごとの `fileExists` を避ける（1 フォルダに数千件ある
            // ライブラリで効く）。取得できなければ安全側に倒して除外する。
            guard let isDirectory = try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  !isDirectory
            else { return false }
            switch PreviewableFileKind.of(filename: child.lastPathComponent, isDirectory: false) {
            case .image, .pdf, .epub, .archive, .video: return true
            case .folder, .other: return false
            }
        }
        let sorted = candidates.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
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
