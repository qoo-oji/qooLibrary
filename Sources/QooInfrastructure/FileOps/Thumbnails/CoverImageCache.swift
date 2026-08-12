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
    /// `identity` に対応するキャッシュファイルの URL。実際に存在するかは
    /// 呼び出し側が判定する。
    func url(for identity: FileIdentity) -> URL
    /// 既にキャッシュされていれば読み込んで返す。
    func loadCachedImage(for identity: FileIdentity) -> CGImage?
    /// サムネイルを保存する。
    @discardableResult
    func store(_ image: CGImage, for identity: FileIdentity) throws -> URL
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

    private let baseDirectory: URL

    /// テストでは独立した一時ディレクトリを渡せる（`SecureExtractor`/
    /// `ArchiveCompressor` の `stagingRoot` 注入と同じ設計判断。CI での
    /// テスト間の競合を避けるため）。
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport.appendingPathComponent("qooLibrary/covers", isDirectory: true)
        }
    }

    public func url(for identity: FileIdentity) -> URL {
        baseDirectory.appendingPathComponent("\(Self.filename(for: identity)).png")
    }

    public func loadCachedImage(for identity: FileIdentity) -> CGImage? {
        let fileURL = url(for: identity)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    public func store(_ image: CGImage, for identity: FileIdentity) throws -> URL {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let fileURL = url(for: identity)
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CoverImageCacheError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CoverImageCacheError.encodingFailed
        }
        return fileURL
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

    private static func filename(for identity: FileIdentity) -> String {
        "\(identity.volumeUUID)-\(identity.inode)"
    }

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
