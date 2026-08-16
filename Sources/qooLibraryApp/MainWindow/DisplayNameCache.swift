import Foundation
import Observation
import QooInfrastructure

/// Finder 準拠のローカライズ表示名を、メインスレッドを止めずに引くための
/// キャッシュ [NV6-02、2026-08 全体点検]。
///
/// `FileManager.displayName(atPath:)` はファイルシステムへ問い合わせる
/// （`.localized` バンドルや拡張子非表示のメタデータを読む）ため、`body` から
/// 直接呼ぶと**描画のたびにメインスレッドが FS を待つ**——応答しない共有では
/// SMB で 30 秒、NFS の hard マウントなら無限に [NV6-02 と同根]。ウインドウ
/// タイトルとパスバーがこの形になっていた（NV6-02 の 4 箇所修正の後に足された
/// 経路で、「済」の記録があっても経路を足したら都度確かめる、の実例）。
///
/// ここでは ①キャッシュにあればそれを返し ②無ければまず `lastPathComponent`
/// を返して、`FileIO` で本物を引けた時点で差し替える（`@Observable` なので
/// 差し替わると自動的に再描画される）。仮の名前が見えるのは初回の一瞬だけ。
///
/// - Note: 表示名はパスに紐づき、改名すればパス自体が変わる（＝別のキー）ので
///   明示的な無効化は要らない。プロセスのローカライズにだけ依存し、アプリ内の
///   表示言語設定（`.environment(\.locale)`、`Text` にしか効かない）には元々
///   追従しないため、キャッシュしても挙動は変わらない。
@MainActor
@Observable
final class DisplayNameCache {
    static let shared = DisplayNameCache()

    private var names: [String: String] = [:]
    private var inFlight: Set<String> = []

    func name(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let cached = names[path] { return cached }
        if !inFlight.contains(path) {
            inFlight.insert(path)
            Task {
                let resolved = await FileIO.perform { FileManager.default.displayName(atPath: path) }
                names[path] = resolved
                inFlight.remove(path)
            }
        }
        // 引けるまでの仮の名前。ルートだけは lastPathComponent が "/" になり
        // 表示に耐えないが、直後にボリューム名へ差し替わる。
        return url.lastPathComponent
    }
}
