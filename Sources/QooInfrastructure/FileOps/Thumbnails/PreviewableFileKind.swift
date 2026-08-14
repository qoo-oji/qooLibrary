import Foundation
import QooKit
import UniformTypeIdentifiers

/// 「中身をどう見せるか」の観点でファイル／フォルダを分類する。
///
/// サムネイル生成（`ThumbnailService`、IV-01）と Quick Look（9.7 節、
/// QL-01〜QL-10）は、どちらも「この項目の中身は画像として見せられるか、
/// 見せられるならどの経路で取り出すか」を判定する必要がある。両者が別々に
/// 拡張子判定を持つと片方だけ更新される事故が起きるため、判定の唯一の
/// 置き場所としてこの型に集約する [設計判断]。
///
/// 実ファイルには触れない純粋な分類（`of(_:)` のディレクトリ判定を除く）で、
/// `FileManager` の変更系 API も使わないため B-10 の対象ではないが、
/// `CoverImageSourceResolver`/`ThumbnailService` と一体で使われるため
/// `ImageLoading` と同じくこのディレクトリに置いている。
public enum PreviewableFileKind: Sendable, Equatable {
    case folder
    /// 画像ファイルそのもの。
    case image
    /// 動画ファイルそのもの（`QLThumbnailGenerator` 経由でサムネイルを作る）。
    case video
    case pdf
    /// EPUB。実体は zip コンテナだが「展開できるアーカイブ」としては扱わない
    /// [`EpubCoverResolver` のコメント参照]。
    case epub
    /// 対応アーカイブ形式 [AR-20〜AR-23]。
    case archive(ArchiveFormat)
    /// 上記のいずれでもない（テキスト・不明な拡張子など）。
    case other

    /// ディレクトリかどうかの判定に 1 回だけ `stat` 相当の I/O を伴う。
    /// 呼び出し側が既に判定済みなら ``of(filename:isDirectory:)`` を使う。
    public static func of(_ url: URL) -> PreviewableFileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .other
        }
        return of(filename: url.lastPathComponent, isDirectory: isDirectory.boolValue)
    }

    public static func of(filename: String, isDirectory: Bool) -> PreviewableFileKind {
        if isDirectory { return .folder }
        // EPUB はアーカイブ判定より先に確定させる（`ArchiveFormat` は `.epub` を
        // 知らないため実害は無いが、判定順に意味があることを明示しておく）。
        if isEpubFilename(filename) { return .epub }
        if let type = utType(of: filename) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .pdf) { return .pdf }
        }
        if let format = ArchiveFormat.from(filename: filename) { return .archive(format) }
        return .other
    }

    /// 標準の Quick Look では中身を見せられず、qooLibrary が生成したカバー画像
    /// （中の先頭画像）に差し替えるべき種別か [QL-03][QL-08]。
    ///
    /// **仕様書 QL-03 は `.cbz`/`.cbr`/`.cb7` のみを挙げているが、実装では
    /// 対応アーカイブ全般とフォルダを対象にする**［ユーザー判断］。理由:
    /// - qooLibrary は `.zip`/`.cbz` を `ArchiveFormat` の同一値として扱い、
    ///   アイコン表示のサムネイルも同じ経路で生成する。拡張子だけで Quick Look
    ///   の挙動が変わると、アプリ内で説明のつかない不整合になる。
    /// - QL-08 が要求するブックフォルダ（8.10 節）はフェーズ 2 の概念だが、
    ///   「配下の先頭画像を出す」という結果は同じであり、フォルダを含めることで
    ///   先取りして満たせる。
    ///
    /// 判定に一致しても、実際にカバー画像を取り出せなければ呼び出し側は元の
    /// URL のまま標準 Quick Look に委ねる（フォルダアイコン等）[IM-04 と同じ
    /// フォールバック方針]。
    public var needsCustomCoverPreview: Bool {
        switch self {
        case .folder, .archive: true
        case .image, .video, .pdf, .epub, .other: false
        }
    }

    // MARK: - 拡張子判定

    public static func isImageFilename(_ name: String) -> Bool {
        utType(of: name)?.conforms(to: .image) ?? false
    }

    public static func isVideoFilename(_ name: String) -> Bool {
        utType(of: name)?.conforms(to: .movie) ?? false
    }

    public static func isPDFFilename(_ name: String) -> Bool {
        utType(of: name)?.conforms(to: .pdf) ?? false
    }

    /// EPUB は `UTType` に共通の静的定数（`.pdf`/`.movie` 等と違い）が標準搭載
    /// されていないため、拡張子の直接比較にしている（`org.idpf.epub-container`
    /// という UTI 自体は macOS 標準搭載だが、`UTType(filenameExtension:)`
    /// 経由の解決に不必要に依存しないため）。
    public static func isEpubFilename(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "epub"
    }

    private static func utType(of name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }
}
