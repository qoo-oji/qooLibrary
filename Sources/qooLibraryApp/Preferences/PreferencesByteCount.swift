import Foundation

/// 環境設定の各タブが出すバイト数の書式。
///
/// `ByteCountFormatter` は 0 バイトを「Zero KB」と書く（`CachePreferencesTab` の
/// 実機検証でユーザーから指摘された既知の癖）ので、0 だけ「0 KB」に直す。
/// 以前はキャッシュ・詳細・リセットの 3 タブがそれぞれ同じ 4 行を private に
/// 持っていた——「バックアップ」タブを分けた回（A3、2026-09-07）に 1 箇所へ寄せた。
enum PreferencesByteCount {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
