import Foundation
import QooKit

/// 実際にバイトを運ぶところ [UI-09][A-04]。`FileOperationService` の
/// コピー・クロスボリューム移動だけがここを使う。
///
/// ## なぜ `FileManager.copyItem` をやめたのか
/// あれは進捗を報告せず、中断もできない。50GB のコピーで「何も分からないまま
/// 待つ」状態を解消するには、バイト単位で進み具合が取れる API が要る。
///
/// ## `copyfile(3)` を選んだ理由と、その前に確かめたこと
/// **`FileManager.copyItem` は APFS 上でクローンしている**（実測: 1GB を 3ms）。
/// 素朴に `copyfile(COPYFILE_ALL)` へ置き換えると同じコピーが 335ms の実コピーに
/// 退行し、ディスクも実際に消費してしまう。そこで **`COPYFILE_CLONE` を必ず
/// 付ける**。実測で次を確認済み:
///
/// | 条件 | 結果 |
/// |---|---|
/// | 同一ボリューム・ファイル | クローン。0 コールバック、1GB が 0ms |
/// | 同一ボリューム・ディレクトリ（`RECURSIVE` 併用）| クローン。2ms |
/// | 別ボリューム・ファイル | 実コピーへ自動的に落ちて**コールバックが届く**（500MB で 477 回）|
/// | 別ボリューム・ディレクトリ | ファイルごとにコールバックが届く（`srcPath` で判別できる）|
/// | `COPYFILE_QUIT` を返す | 中断され、**書きかけの宛先は copyfile 自身が消す** |
///
/// つまりこの 1 組で「速い経路を守ったまま、遅い経路にだけ進捗と中断を足す」が
/// 両立する。
///
/// ## 中断
/// `Cancellation.isRequested` をコールバックから読む。`copyfile` は呼び出し元の
/// スレッドで同期的に走るので、タスクの文脈がそのまま生きている。
/// UI 側は進捗シートの「キャンセル」でタスクを取り消すだけでよい。
enum FileCopyEngine {
    /// コピー中に起きたこと。
    enum Outcome {
        /// 最後まで運び終えた。`bytes` は実際に書いたバイト数
        /// （クローンできた場合は 0 — 1 バイトも書いていないため）。
        case completed(bytes: Int64)
        /// ユーザーが中断した。宛先は `copyfile` が後始末済み。
        case cancelled
    }

    /// `source` を `destination` へ複製する。`destination` は存在しない前提
    /// （衝突は呼び出し側が解決済み）。
    ///
    /// - Parameter onBytesCopied: 実コピーになった場合だけ、**増分**バイト数で
    ///   呼ばれる。クローンできた場合は一度も呼ばれない。
    /// - Parameter allowsCloning: `false` にすると必ず実コピーになる。
    ///   **テストのための逃げ道** — 進捗と中断が働くのはクローンできない経路
    ///   だけであり、その経路を確かめるには本来もう 1 つボリュームが要る。
    ///   本番の呼び出し元はこれを指定しない。
    static func copy(
        from source: URL,
        to destination: URL,
        allowsCloning: Bool = true,
        pauseToken: PauseToken? = nil,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let context = CallbackContext(onBytesCopied: onBytesCopied, pauseToken: pauseToken)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(statusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        // - `NOFOLLOW`: シンボリックリンクは追跡せずリンクとして複製する
        //   [SL-01]（`FileManager.copyItem` と同じ挙動）。
        // - `EXCL`: 宛先が既にあれば失敗する。衝突は事前に解決してある約束
        //   なので、これは「取りこぼした衝突で健康なファイルを黙って書き潰さ
        //   ない」ための安全弁。`FileManager.copyItem` が元々持っていた性質で
        //   もあり、差し替えで失ってはならない。
        //
        // **`COPYFILE_EXCL` は必ず自分で指定する。** man page には
        // `COPYFILE_CLONE` が `NOFOLLOW|ALL|EXCL` を含むと書かれているが、
        // **実際には既存の宛先を黙って上書きした**（回帰テスト
        // `refusesToOverwriteAnExistingDestination` が実測で捕まえた）。
        // ドキュメントの「implies」を信じないこと。
        let base = COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_RECURSIVE
        let flags = copyfile_flags_t(allowsCloning ? base | COPYFILE_CLONE : base)
        let result = copyfile(source.path, destination.path, state, flags)
        let failure = errno // `copyfile` の直後に読む（以降の呼び出しで壊れる）

        if result == 0 { return .completed(bytes: context.totalCopied) }
        if context.didCancel { return .cancelled }
        // **errno を文字列へ畳まずに渡す** [ER-03]。呼び出し側が「容量不足
        // なのか権限なのか」を区別して、次に何ができるかを言えるようにする。
        throw FileOperationError.copyFailed(source: source, destination: destination, errnoCode: failure)
    }

    /// `copyfile` の status コールバックが読み書きする箱。
    ///
    /// **`copyfile` は同期的に呼び出し元のスレッドで走る**ため、この箱に
    /// 並行アクセスは無い（複数スレッドから同時に使われることは無い）。
    private final class CallbackContext {
        let onBytesCopied: (Int64) -> Void
        let pauseToken: PauseToken?
        var totalCopied: Int64 = 0
        var didCancel = false
        /// ディレクトリを再帰コピーしているとき、`COPYFILE_STATE_COPIED` は
        /// **今のファイルの累計**を返す。全体の累計を出すには、ファイルが
        /// 変わった時点で基準を取り直して増分を積む必要がある。
        var currentFilePath: String?
        var currentFileCopied: Int64 = 0

        init(onBytesCopied: @escaping (Int64) -> Void, pauseToken: PauseToken?) {
            self.onBytesCopied = onBytesCopied
            self.pauseToken = pauseToken
        }

        func note(path: String, copiedSoFar: Int64) {
            if path != currentFilePath {
                currentFilePath = path
                currentFileCopied = 0
            }
            let delta = copiedSoFar - currentFileCopied
            guard delta > 0 else { return }
            currentFileCopied = copiedSoFar
            totalCopied += delta
            onBytesCopied(delta)
        }
    }

    /// **`@MainActor` の型の内側に置かない** — C の関数ポインタへ変換される
    /// クロージャがアクタ隔離とみなされ、実行アクタの表明で落ちる
    /// （`FileSystemEventStream` で実際に踏んだ罠）。`enum` の `static` は
    /// どのアクタにも属さないのでここは安全。
    private static let statusCallback: copyfile_callback_t = { what, stage, state, sourcePath, _, contextPointer in
        guard let contextPointer else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CallbackContext>.fromOpaque(contextPointer).takeUnretainedValue()

        // 中断はどの段階でも受け付ける（大きな 1 ファイルの途中でも止まれる）。
        if Cancellation.isRequested {
            context.didCancel = true
            return COPYFILE_QUIT
        }

        // 一時停止はここで待つ [ユーザー要望]。`copyfile` は呼び出し元の
        // スレッドで同期的に走るので、待てばそのままコピーが止まる。
        // 待っている間もキャンセルは効く（`PauseToken` 参照）ので、
        // 抜けた直後に取り消しをもう一度見る。
        if let token = context.pauseToken, token.isPaused {
            token.waitWhilePaused()
            if Cancellation.isRequested {
                context.didCancel = true
                return COPYFILE_QUIT
            }
        }

        // **エラー段階で `COPYFILE_CONTINUE` を返してはいけない。**
        // それは `copyfile` に「その失敗は無視して続けろ」と指示することになり、
        // 最終的な戻り値まで 0（成功）になる。status コールバックを付けた
        // 瞬間に、既存の宛先を拒む `COPYFILE_EXCL` も、権限エラーも、
        // ディスク不足も、すべて黙って握り潰される状態になっていた
        // （回帰テスト `refusesToOverwriteAnExistingDestination` が捕まえた）。
        // `COPYFILE_QUIT` を返せば `copyfile` は -1 を返し errno も立つ。
        if stage == COPYFILE_ERR { return COPYFILE_QUIT }

        guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else { return COPYFILE_CONTINUE }
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.note(path: sourcePath.map { String(cString: $0) } ?? "", copiedSoFar: Int64(copied))
        return COPYFILE_CONTINUE
    }
}
