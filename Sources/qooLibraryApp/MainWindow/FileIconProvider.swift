import AppKit

/// フォルダツリー・リスト表示・アイコン表示の既定アイコンを Finder と同じものに
/// する [ユーザー要望: SF Symbol の代用アイコンでは視認性が良くない]。
///
/// `NSWorkspace.icon(forFile:)` は公開 API で、App Sandbox 下でも追加の
/// entitlement なしに動作する（Launch Services への問い合わせのみで、ファイル
/// 内容の読み取りを伴わない）。カスタムフォルダアイコン・拡張子別のアイコン・
/// アプリバンドルのアイコンいずれも Finder と同一のものが得られる。
///
/// リスト・ツリー表示は行数が多くなり得るため、パスごとに単純なメモリキャッシュ
/// を持つ（`NSWorkspace` への問い合わせ自体は IPC を伴い、行の再描画のたびに
/// 呼び直すとスクロール時にコストがかかるため）。ディスクへの永続化はしない
/// （サムネイルと違いデコードコストが無く、プロセス起動のたびに再取得すれば
/// 十分軽いため）。
@MainActor
final class FileIconProvider {
    static let shared = FileIconProvider()
    private init() {}

    private var cache: [String: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let key = url.path
        if let cached = cache[key] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = icon
        return icon
    }
}
