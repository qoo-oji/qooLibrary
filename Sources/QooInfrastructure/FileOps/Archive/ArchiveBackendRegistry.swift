import Foundation
import QooKit

/// 形式・ビルドフラグに応じたバックエンドの選択 [9.1 節]。呼び出し側は
/// ここだけを見ればよく、`PERMISSIVE_ONLY_BUILD` の有無が他へ波及しない
/// [AB-01][MT-04]。
public enum ArchiveBackendRegistry {
    public static func reader(for format: ArchiveFormat) -> any ArchiveReading {
        switch format {
        case .rar:
            #if PERMISSIVE_ONLY_BUILD
            return LibarchiveBackend.shared // [LC-12][LC-13]
            #else
            return UnrarBackend.shared // [LC-11]
            #endif
        case .zip, .sevenZip, .tarGz:
            return LibarchiveBackend.shared // [LC-14]
        }
    }

    public static func reader(for url: URL) -> (any ArchiveReading)? {
        guard let format = ArchiveFormat.from(filename: url.lastPathComponent) else { return nil }
        return reader(for: format)
    }

    /// アバウト画面・診断情報用 [B-01]。
    public static var rarBackendName: String {
        #if PERMISSIVE_ONLY_BUILD
        "libarchive (PERMISSIVE_ONLY_BUILD)"
        #else
        "UnRAR"
        #endif
    }
}
