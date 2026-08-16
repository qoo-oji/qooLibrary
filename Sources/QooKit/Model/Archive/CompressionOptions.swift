import Foundation

/// 書き込み（圧縮）に対応する形式。`ArchiveFormat` は読み取り専用の
/// rar/tarGz も含む4種のため、無効な組み合わせ（例: rar を圧縮先に選ぶ）を
/// 型で排除するために専用の列挙にする。
public enum CompressibleFormat: String, Sendable, Codable, CaseIterable {
    case zip
    case sevenZip

    public var archiveFormat: ArchiveFormat {
        switch self {
        case .zip: .zip
        case .sevenZip: .sevenZip
        }
    }
}

/// 7z の圧縮コーデック [環境設定「圧縮／展開」タブ]。libarchive の 7z
/// ライターは liblzma（LZMA1/LZMA2）を同梱していないビルドのため対象外。
/// PPMd は外部依存無しで同梱済み、bzip2/deflate はシステムライブラリに
/// リンク済み（`nm`/`strings` による実機確認済み、CLAUDE.md 参照）。
public enum SevenZipCodec: String, Sendable, Codable, CaseIterable {
    case ppmd
    case bzip2
    case deflate
    case copy
}

/// zip の圧縮レベル。libarchive の `zip:compression-level`（0〜9）に
/// そのまま渡す。
public enum ZipCompressionLevel: Int, Sendable, Codable, CaseIterable {
    case store = 0
    case fast = 3
    case normal = 6
    case best = 9
}

/// アーカイブの暗号化方式。**zip 形式でのみ有効**（libarchive の 7z ライターは
/// 暗号化オプション自体を持たない、`archive_write_set_format_7zip.c` で確認
/// 済み）。`zipTraditional` は既知の攻撃手法で短時間に突破可能な弱い暗号化
/// のため、UI 側で明確に警告を表示すること。
public enum ArchiveEncryptionMethod: String, Sendable, Codable, CaseIterable {
    case none
    case zipTraditional
    case aes128
    case aes256

    /// libarchive の `zip:encryption` オプション値。`.none` は非該当。
    public var zipOptionValue: String? {
        switch self {
        case .none: nil
        case .zipTraditional: "zipcrypt"
        case .aes128: "aes128"
        case .aes256: "aes256"
        }
    }
}

/// 圧縮時の設定一式 [環境設定「圧縮／展開」タブ]。**パスワード文字列自体は
/// 含まない** — `UserDefaults` に平文で既定パスワードを保存するのはセキュリティ
/// 上望ましくないため、実際のパスワードは圧縮操作のたびにシート
/// （`ArchivePasswordDialog`）で入力させる設計にしている。この型が持つのは
/// 「暗号化するかどうか、その方式」だけ。
public struct CompressionOptions: Sendable, Equatable {
    public var format: CompressibleFormat
    public var zipLevel: ZipCompressionLevel
    public var sevenZipCodec: SevenZipCodec
    public var encryption: ArchiveEncryptionMethod

    public init(
        format: CompressibleFormat = .zip,
        zipLevel: ZipCompressionLevel = .normal,
        sevenZipCodec: SevenZipCodec = .ppmd,
        encryption: ArchiveEncryptionMethod = .none
    ) {
        self.format = format
        self.zipLevel = zipLevel
        self.sevenZipCodec = sevenZipCodec
        self.encryption = encryption
    }

    public static let `default` = CompressionOptions()
}
