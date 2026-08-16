import Foundation

/// **ブロッキングなファイル I/O 専用のスレッド源** [NV6-01]。
///
/// ## なぜ要るのか（実測）
/// Swift の協調スレッドプールは**論理コア数ぶんのスレッドしか持たない**。
/// そこでブロッキング I/O をすると、そのスレッドはランタイムから見えないまま
/// 塞がる。1-16b の実測（論理コア 10 の機）:
///
/// > コア数ぶんの同期ブロッキング I/O を `Task` で走らせたところ、
/// > **ごく普通の `Task` が 5 秒間一度も動かなかった。**
///
/// つまり **1 つの応答しないサーバが、アプリの async 処理を全部止める**。
/// しかも `Task.detached` も同じプールを使うので、逃げ場にならない。
///
/// ネットワークでは待ち時間の桁が違う:
///
/// | プロトコル | 無応答時 |
/// |---|---|
/// | SMB | `nsmb.conf` の `max_resp_timeout` 既定 **30 秒** |
/// | **NFS（hard マウント＝既定）** | **割り込み不能に無限**。`kill` も効かないことがある |
/// | FUSE-T（macFUSE の後継。rclone/SSHFS 等）| NFSv4 ループバックとして実装され、同じ特性 |
///
/// SMB なら 30 秒で解放される（一時的な劣化）が、**NFS ではスレッドが
/// 永久に失われる**。協調プールでこれを起こしてはならない。
///
/// ## なぜ `DispatchQueue` なのか
/// **libdispatch は協調プールと設計思想が逆**で、スレッドがブロックすると
/// 必要に応じて新しいスレッドを起こす（QoS ごとに 64 本程度が上限）。
/// ここではその性質がちょうど欲しいものになる——**塞がったスレッドは
/// 犠牲にして、後続の仕事は別のスレッドで進める。**
///
/// 同時実行数を絞りすぎないのは意図的で、実際の並行度は呼び出し側が
/// 既に制限している（`ThumbnailService` のスロット [PF-11]、
/// コマンドが 1 つずつ実行されること）。ここで更に絞ると、
/// **1 件のハングが全体を止める**という直したかった性質が戻ってくる。
///
/// ## `TaskExecutor` 適合について
/// `withTaskExecutorPreference(_:)` で async の呼び出し木ごと載せられるよう
/// 適合している。ただし**既定の使い方は ``FileIO/perform(_:)``** で、
/// そちらは継続で明示的に飛び移るため、
/// 「`Task {}` や `Task.detached` は preference を継承しない」という
/// SE-0417 の細かい規則に依存しない。
public final class FileIOExecutor: TaskExecutor, @unchecked Sendable {
    public static let shared = FileIOExecutor()

    /// `.userInitiated` — ユーザーの操作に直結する仕事（一覧を出す、ファイルを
    /// 運ぶ）が大半なので、既定より 1 段高くする。`.userInteractive` にはしない
    /// （そちらは描画のための優先度で、I/O が奪うべきではない）。
    let queue = DispatchQueue(
        label: "com.qoolibrary.fileio",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
