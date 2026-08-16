import AppKit
import Observation
import QooInfrastructure
import UniformTypeIdentifiers

/// フォルダツリー・リスト表示・アイコン表示の既定アイコンを Finder と同じものに
/// する [ユーザー要望: SF Symbol の代用アイコンでは視認性が良くない]。
///
/// ## `NSWorkspace.icon(forFile:)` は「例外」ではなかった【実測で訂正】
/// NV6-02 はこの API を**メインスレッドで呼んでよい例外**として挙げていた
/// ——「Launch Services への問い合わせのみで、ファイル内容の読み取りを
/// 伴わない。SMB でも 0.1〜0.4ms」。**それは接続中しか測っていなかった。**
///
/// 遮断計測（`Scripts/network-disconnect-probe.sh` の項目 13）で、
/// **到達できない共有上のパスに対して 30 秒ブロックする**ことが分かった
/// （SMB の `max_resp_timeout` 既定）。しかも**失敗せず「返った」**ので、
/// 症状は「アプリが 30 秒固まる」だけになる。
///
/// これは `RENAME_EXCL` で一度踏んだのと同じ形——**興味のあるケースだけ
/// 測って一般化した**——である（8章 §8.11.15）。
///
/// ## ローカルは同期のまま、リモートだけ非同期にする
/// 素朴に全部を非同期化すると、**ローカルでも一瞬だけ汎用アイコンが出る**。
/// アイコンは名前より目に付くうえ、ローカルでの取得は 0.1ms 程度なので、
/// それは失うものが大きすぎる。行き先のボリュームで振り分ける:
///
/// | 場所 | 振る舞い |
/// |---|---|
/// | 起動ボリューム・ローカル | **従来どおり同期**。見た目は一切変わらない |
/// | ネットワーク | 汎用アイコンを即返し、引けた時点で差し替える |
///
/// 判定は ``MountTable``（マウント表を読むだけで、ファイルシステムへ
/// 問い合わせない＝切断中も固まらない）で行い、**ボリューム単位で覚える**
/// ので、行ごとに数えても費用は実質ゼロになる。
///
/// - Note: **キャッシュに上限が無い**のは以前からの性質で、ここでは変えて
///   いない（変えると再取得で汎用アイコンが一瞬出る）。数万件を渡り歩く
///   使い方では効いてくるので、必要になったら上限と追い出しを入れること。
@MainActor
@Observable
final class FileIconProvider {
    static let shared = FileIconProvider()
    private init() {}

    /// **`@ObservationIgnored`** — `body` の評価中に書き込むため。観測対象の
    /// プロパティを描画中に書き換えるのは SwiftUI では未定義動作なので、
    /// 実体は観測から外し、差し替えの通知だけ ``generation`` で行う。
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// ボリュームの入口（`/Volumes/<名前>`）ごとの「ネットワークか」。
    /// `nil` キーは起動ボリューム。
    @ObservationIgnored private var remoteByVolume: [String: Bool] = [:]

    /// 差し替えが起きたことだけを伝える観測対象。**非同期の完了からのみ**
    /// 書き換える（描画中には触らない）。
    private var generation = 0

    /// - Parameter isDirectory: 分かっていれば渡す。引けるまでの仮アイコンを
    ///   フォルダにするか書類にするかにだけ使う（**パスを見ないので
    ///   ファイルシステムへは出ない**）。
    func icon(for url: URL, isDirectory: Bool? = nil) -> NSImage {
        _ = generation // 差し替えで再描画されるよう、依存を登録しておく。
        let key = url.path
        if let cached = cache[key] { return cached }

        guard isOnRemoteVolume(key) else {
            // ローカル: 従来どおりその場で引く。0.1ms 程度で、応答しない
            // 相手が居ないので待たされる心配が無い。
            let icon = NSWorkspace.shared.icon(forFile: key)
            cache[key] = icon
            return icon
        }

        if !inFlight.contains(key) {
            inFlight.insert(key)
            Task { [key] in
                let fetched = await FileIO.perform { IconBox(NSWorkspace.shared.icon(forFile: key)) }
                cache[key] = fetched.image
                inFlight.remove(key)
                generation &+= 1
            }
        }
        return Self.placeholder(isDirectory: isDirectory)
    }

    // MARK: - 行き先の見分け

    /// **マウント表だけで判定する。** `resourceValues` や `statfs` は対象の
    /// ボリュームへ問い合わせるので、ここで使うと「固まるのを避けるための
    /// 判定」が固まる。
    private func isOnRemoteVolume(_ path: String) -> Bool {
        // 起動ボリューム上なら考えるまでもない（純粋な文字列処理）。
        guard let volumeRoot = MountTable.volumeRoot(of: path) else { return false }
        if let known = remoteByVolume[volumeRoot] { return known }
        let isRemote = MountTable.current().isRemote(path: volumeRoot)
        remoteByVolume[volumeRoot] = isRemote
        return isRemote
    }

    // MARK: - 仮アイコン

    /// 種別だけから引く。**パスを渡さないので、どのボリュームにも触れない。**
    private static func placeholder(isDirectory: Bool?) -> NSImage {
        (isDirectory ?? false) ? folderPlaceholder : itemPlaceholder
    }

    private static let folderPlaceholder = NSWorkspace.shared.icon(for: .folder)
    private static let itemPlaceholder = NSWorkspace.shared.icon(for: .item)
}

/// `NSImage` は `Sendable` ではないので、``FileIO`` の境界を越えるために包む。
///
/// ここで渡るのは `NSWorkspace` が作った直後のアイコンで、**誰も変更しない**
/// （受け取った側もキャッシュに入れて描画に使うだけ）。共有された可変状態を
/// 持ち回るわけではないため `@unchecked` で差し支えない。
private struct IconBox: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
