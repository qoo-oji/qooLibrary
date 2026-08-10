import Foundation

/// 対応アーカイブ形式 [9.1 節]。`cbz`/`cb7`/`cbr` はそれぞれ zip/7z/rar の
/// エイリアス拡張子として扱う。
public enum ArchiveFormat: String, Sendable, CaseIterable, Equatable {
    case zip
    case sevenZip
    case rar
    case tarGz

    /// 単一の拡張子（`pathExtension` 相当）から判定する。`tar.gz` のような
    /// 複合拡張子は判定できないため、ファイル名全体から判定したい場合は
    /// ``from(filename:)`` を使う。
    public static func from(fileExtension: String) -> ArchiveFormat? {
        switch fileExtension.lowercased() {
        case "zip", "cbz": return .zip
        case "7z", "cb7": return .sevenZip
        case "rar", "cbr": return .rar
        case "tar.gz", "tgz", "gz": return .tarGz
        default: return nil
        }
    }

    /// ファイル名全体から判定する。`.tar.gz` の複合拡張子を単独の `.gz` と
    /// 誤判定しないよう、まず末尾一致で確認する。
    public static func from(filename: String) -> ArchiveFormat? {
        let lower = filename.lowercased()
        if lower.hasSuffix(".tar.gz") { return .tarGz }
        return from(fileExtension: (filename as NSString).pathExtension)
    }
}
