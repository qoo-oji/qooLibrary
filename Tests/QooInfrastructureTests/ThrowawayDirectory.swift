import Foundation

/// 共有・クラウド上に作った使い捨てフォルダを、**本当に消えるまで**片付ける。
///
/// ## なぜ専用の関数が要るのか
/// 素朴に書くとこうなる（実際そう書かれていた）:
///
/// ```swift
/// for _ in 0..<10 where fm.fileExists(atPath: dir.path) {
///     try? fm.removeItem(at: dir)
///     if fm.fileExists(atPath: dir.path) { Thread.sleep(forTimeInterval: 0.2) }
/// }
/// ```
///
/// これは**成否を `fileExists` から推測している**。SMB クライアントは
/// ディレクトリ情報を最大 30 秒キャッシュする（`nsmb.conf` の `dir_cache_min`
/// 既定、8章 §8.11.5）ので、**削除に失敗しているのに `fileExists` が
/// 古い `false` を返す**ことがある。すると `try?` が握りつぶした失敗と
/// 合わさって、「削除しました」と報告しながら相手の共有にフォルダが残る。
///
/// 実際に遮断計測の後片付けがこれを踏み、**再接続直後に消し損ねたフォルダが
/// NAS に残った**（報告は成功だった）。あとから素の `rm` を投げると 1 回で
/// 消えたので、「消せない」のではなく「消えたことにされていた」もの。
///
/// ここでは **`removeItem` が投げたエラーだけを信じる**。`ENOENT` は
/// 「既に無い」＝成功として扱う。
///
/// - Returns: 消し切れなかった場合の最後のエラー。成功なら `nil`。
@discardableResult
func removeThrowawayDirectory(
    at url: URL,
    attempts: Int = 10,
    delay: TimeInterval = 0.3
) -> Error? {
    var lastError: Error?
    for attempt in 0..<attempts {
        if attempt > 0 { Thread.sleep(forTimeInterval: delay) }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch let error as NSError {
            // 既に無いなら成功。`NSFileNoSuchFileError` と POSIX の ENOENT の
            // どちらで来るかは経路によって変わるため両方を見る。
            if error.code == NSFileNoSuchFileError
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            {
                return nil
            }
            lastError = error
        }
    }
    return lastError
}
