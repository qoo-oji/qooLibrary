import CoreGraphics
import Foundation
import ImageIO
import QooKit
import UniformTypeIdentifiers

/// サムネイルのディスクキャッシュ [9.6 節、IV-09][CL-05]。
///
/// 仕様書の `CoverImageCache` は `fileID: UUID, libraryID: UUID` で
/// キー付けするが、これは SwiftData の `Library`/`ManagedFile` を前提とした
/// フェーズ2以降の設計。フェーズ1にはまだ DB もライブラリ登録も無いため、
/// 既に `QooKit` にある `FileIdentity`（volumeUUID + inode、DB 抜きでも
/// 使える値型）でキー付けする形に落とし込んでいる。ユーザー指定カバー画像
/// （TH-04、元の拡張子を保った複製）は Phase 2 の対象なので、このキャッシュは
/// 「自動生成したサムネイルを PNG で保存するだけ」に単純化している
/// （元画像の形式を問わず、生成物を一貫した形式で保存すればよいため）。
public protocol CoverImageCache: Sendable {
    /// `stamp` に対応するキャッシュファイルの URL。実際に存在するかは
    /// 呼び出し側が判定する。
    func url(for stamp: FileContentStamp) -> URL
    /// 既にキャッシュされていれば読み込んで返す。
    func loadCachedImage(for stamp: FileContentStamp) -> CGImage?
    /// サムネイルを保存する。
    @discardableResult
    func store(_ image: CGImage, for stamp: FileContentStamp) throws -> URL
    /// そのファイルのキャッシュを、**内容の版によらずすべて**捨てる。
    /// 「サムネイルを再生成」のように、対象を URL でしか特定できない
    /// 呼び出し元のためのもの。
    func removeEntries(for identity: FileIdentity) async
    func totalSize() async -> Int64
    /// 合計サイズが `maxSize` 以下になるまで、古いものから削除する [IV-09]。
    func prune(toMaxSize: Int64) async
    /// キャッシュを空にする [IV-09、環境設定の「手動クリア」用]。
    func clear() async
}

/// `~/Library/Application Support/qooLibrary/covers/` を使う既定実装。
/// ライブラリ登録（1-13）が無いフェーズ1では単一の共有キャッシュとして扱う
/// （仕様書の `<libraryUUID>/` によるライブラリごとの分離は、実際に複数の
/// ライブラリを区別する必要が生じる Phase 2 で導入する）。
public struct DefaultCoverImageCache: CoverImageCache {
    public static let shared = DefaultCoverImageCache()

    /// 鍵の形式が変わったときのための版。**形式を変えたらここを上げること** —
    /// 古い形式で作ったファイルは新しい鍵では二度と引かれず、上限
    /// [IV-09] に達するまで場所を占め続けるため、版ごとにディレクトリを
    /// 分けて丸ごと捨てられるようにしてある。
    ///
    /// - v1 … `<volumeUUID>-<inode>` （`FileIdentity` のみ）
    /// - v2 … `FileContentStamp.cacheKey`（更新日時・サイズを含む）
    private static let versionDirectoryName = "v2"

    private let baseDirectory: URL
    /// 版ディレクトリの親。既定の場所を使うときだけ値が入る
    /// （``purgeOutdatedVersions()`` が消してよい範囲を、注入された
    /// ディレクトリへ広げないため）。
    private let versionedRoot: URL?

    /// テストでは独立した一時ディレクトリを渡せる（`SecureExtractor`/
    /// `ArchiveCompressor` の `stagingRoot` 注入と同じ設計判断。CI での
    /// テスト間の競合を避けるため）。
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
            self.versionedRoot = nil
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let root = appSupport.appendingPathComponent("qooLibrary/covers", isDirectory: true)
            self.versionedRoot = root
            self.baseDirectory = root.appendingPathComponent(Self.versionDirectoryName, isDirectory: true)
        }
    }

    /// 古い鍵の形式で作られたキャッシュを捨てる。アプリ起動時に一度呼ぶ
    /// （`SecureExtractor.cleanupResidualStaging()` と同じ位置づけ）。
    ///
    /// テスト等でディレクトリを注入した場合は何もしない — 消してよい範囲が
    /// 分からないため。
    public func purgeOutdatedVersions() async {
        guard let versionedRoot else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: versionedRoot, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent != Self.versionDirectoryName {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    public func url(for stamp: FileContentStamp) -> URL {
        baseDirectory.appendingPathComponent("\(stamp.cacheKey).png")
    }

    public func loadCachedImage(for stamp: FileContentStamp) -> CGImage? {
        let fileURL = url(for: stamp)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    public func store(_ image: CGImage, for stamp: FileContentStamp) throws -> URL {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let fileURL = url(for: stamp)
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CoverImageCacheError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CoverImageCacheError.encodingFailed
        }
        return fileURL
    }

    public func removeEntries(for identity: FileIdentity) async {
        let prefix = FileContentStamp.cacheKeyPrefix(for: identity)
        for file in cachedFiles() where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func totalSize() async -> Int64 {
        cachedFiles().reduce(Int64(0)) { $0 + (fileSize($1) ?? 0) }
    }

    public func prune(toMaxSize maxSize: Int64) async {
        var files = cachedFiles().map { url in (url: url, size: fileSize(url) ?? 0, date: modificationDate(url)) }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxSize else { return }
        // 古いものから削除する [IV-09]。
        files.sort { $0.date < $1.date }
        for file in files {
            guard total > maxSize else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    public func clear() async {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: - 内部

    private func cachedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}

public enum CoverImageCacheError: Error, Sendable, Equatable {
    case encodingFailed
}
