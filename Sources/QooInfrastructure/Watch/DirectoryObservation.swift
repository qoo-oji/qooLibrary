import Foundation
import Observation

/// 1 つの表示が 1 つのフォルダを見張るための取っ手 [10章 §10.0]。
///
/// `DirectoryChangeHub` が変更を検知するたび ``generation`` が増える。購読側は
/// **その値を `body` の中で読む**ことで Observation の依存に載せ、増えたら
/// 読み直す。
///
/// ```swift
/// @State private var watch = DirectoryObservation()
/// …
/// .onChange(of: watch.generation) { reload() }
/// ```
///
/// ## なぜ「コールバックを預ける」形にしないのか
/// このコードベースでは、値型の View が保持する `let` を非表示ボタンの
/// クロージャから読むと 1 世代古い値を掴む、という罠を繰り返し踏んでいる
/// （`FolderContentView.currentFolder` のコメント参照）。ハブにクロージャを
/// 預けると同じ罠が再現するうえ、ハブが View を強参照して解放されなくなる。
/// **値（世代番号）だけを配り、何をするかは購読側が `body` の評価ごとに
/// 最新の文脈で決める**ことで、その種類の不具合が構造的に起こらない。
///
/// ## 生存期間
/// `@State` に持たせれば、そのビューが生きている間だけ登録が残り、解放時に
/// ``deinit`` が登録を解く。ハブ側も弱参照でしか保持しないので、解除を
/// 取りこぼしても登録が生き残ることは無い。
@MainActor
@Observable
public final class DirectoryObservation {
    /// 変更が届くたびに増える。**これを `body` から読むことが購読になる。**
    public private(set) var generation: Int = 0

    /// ハブ側の登録キー。`deinit`（`nonisolated`）から読むため
    /// `nonisolated let`（`UUID` は `Sendable`）。
    @ObservationIgnored
    private nonisolated let token = UUID()

    /// `deinit` から登録を解くため `nonisolated let`
    /// （`DirectoryChangeHub` は `@MainActor` なので `Sendable`）。
    @ObservationIgnored
    private nonisolated let hub: DirectoryChangeHub

    public init(hub: DirectoryChangeHub = .shared) {
        self.hub = hub
    }

    deinit {
        let token = self.token
        Task { @MainActor [hub] in hub.unregister(token) }
    }

    /// 見張る対象を設定する。同じ対象なら何もしないので、`onChange` の
    /// `initial: true` などから繰り返し呼んでよい。`nil` を渡すと見張りを解く。
    public func watch(_ url: URL?, scope: DirectoryWatchScope = .shallow) {
        hub.register(self, token: token, url: url, scope: scope)
    }

    func markChanged() {
        generation &+= 1
    }
}
