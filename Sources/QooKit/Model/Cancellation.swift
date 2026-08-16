import Foundation

/// **借りたスレッドの上でも取り消しを見られるようにする** [NV6-01][NV6-03]。
///
/// ## なぜ `Task.isCancelled` では足りないのか（実測で踏んだ）
/// ブロッキング I/O は協調スレッドプールから追い出す必要がある（応答しない
/// サーバ 1 件でアプリの `async` 処理が全部止まるため。8章 §8.11.6）。
/// その追い出し先は素の `DispatchQueue` で、**そこには Task の文脈が無い**。
///
/// `Task.isCancelled` は現在のタスクを見るので、タスクが無ければ**常に
/// `false`** を返す。つまり `FileIO.perform` の中へ処理を移した瞬間、
/// そこにあった取り消し判定は**エラーも警告も出さずに死ぬ**:
///
/// | 死ぬもの | 結果 |
/// |---|---|
/// | `PauseToken.waitWhilePaused` | 一時停止した処理を**二度と止められない**（実測: テストが永久にハングした）|
/// | `FileCopyEngine` の status コールバック | コピーのキャンセルが効かない |
/// | `ProgressTracker.walk` | 5 万件の走査を打ち切れない |
/// | アーカイブ各バックエンド | [EX-24] の中断が効かない |
///
/// **どれもコンパイルは通り、テストの多くも通ってしまう**（取り消しを
/// 実際に試すテストだけが落ちる）。1-15 の「`Task.detached` は呼び出し元の
/// キャンセルを引き継がない」と同じ種類の、**仕組みは正しく見えるのに
/// 前提が静かに崩れている**罠である。
///
/// ## この型が答えること
/// 「いま自分がやっている仕事は、取り消しを要求されたか」を、
/// **タスクの上でも、借りたスレッドの上でも**同じように答える。
///
/// - `FileIO.perform` のように**スレッドを借りる側**が ``withScope(_:_:)``
///   で範囲を宣言し、呼び出し元タスクの取り消しを ``Flag/request()`` で伝える。
/// - **中で働く側**は `Task.isCancelled` の代わりに ``isRequested`` を読む。
///   範囲の中なら旗を、外なら `Task.isCancelled` を見るので、
///   **どちらの世界から呼ばれても正しく動く**。
///
/// ## 静的検査で守る
/// 「`Task.isCancelled` を書いてしまう」ことは人間には見分けが付かないので、
/// `Scripts/check-cancellation-usage.swift` が `QooInfrastructure/FileOps/`
/// 配下での `Task.isCancelled` を検出してビルドを失敗させる。
///
/// ## 取り消しは「やめてくれ」であって「止める」ではない
/// macOS に中断可能なファイル I/O は無い [NV6-03]。旗を立てても、走っている
/// `copyfile` や `read(2)` は最後まで走る。旗を見るのは**次の区切り**まで
/// 進んだときであり、区切りの無い 1 回の syscall の途中では効かない。
public enum Cancellation {
    /// 1 つの仕事に対する取り消し要求。立てるのは 1 回だけで、下ろせない。
    ///
    /// `NSLock` で守る。読み出しは走査の中で数万回呼ばれ得るが、競合の無い
    /// `NSLock` は数十ナノ秒なので、5 万件でも合計 1ms 程度にとどまる。
    public final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var requested = false

        public init() {}

        /// 取り消しを要求する。**何度呼んでもよい。**
        public func request() {
            lock.lock()
            requested = true
            lock.unlock()
        }

        public var isRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }
    }

    /// いま取り消しを要求されているか。
    ///
    /// ``withScope(_:_:)`` の中なら**その旗**を、外なら `Task.isCancelled` を
    /// 見る。したがって**呼ぶ側はどちらの世界にいるかを知らなくてよい**。
    public static var isRequested: Bool {
        if let raw = pthread_getspecific(key) {
            return Unmanaged<Flag>.fromOpaque(raw).takeUnretainedValue().isRequested
        }
        return Task.isCancelled
    }

    /// このスレッドの上で走る `body` を `flag` に結び付ける。
    ///
    /// - Important: `flag` は `body` が終わるまで**呼び出し側が保持する**こと
    ///   （ここでは所有権を取らない）。入れ子にしても、前の結び付きを
    ///   `defer` で必ず戻すので壊れない。
    public static func withScope<T>(_ flag: Flag, _ body: () throws -> T) rethrows -> T {
        let previous = pthread_getspecific(key)
        pthread_setspecific(key, Unmanaged.passUnretained(flag).toOpaque())
        defer { pthread_setspecific(key, previous) }
        return try body()
    }

    /// スレッドごとに「いまどの旗を見るか」を持つ場所。
    ///
    /// `Thread.threadDictionary` ではなく pthread の TLS を使うのは速さのため
    /// （前者は `NSMutableDictionary` への橋渡しを伴い、走査の内側で数万回
    /// 読むには重い）。破棄関数を渡さないのは、値が非所有のポインタで
    /// あって、ここで解放してはならないため。
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()
}
