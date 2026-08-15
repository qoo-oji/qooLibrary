import Foundation
import QooKit

/// **元を消す前に、運んだ結果が元と一致することを確かめる。**
///
/// ## なぜ要るのか（ユーザー指摘）
/// クロスボリュームの移動は「コピーしてから元を消す」。写した内容が元と
/// 食い違っていると、**消した時点でその差分は永久に失われる**。
///
/// 食い違いは、他のアプリが書き込み中のファイル（ダウンロード中、書き出し中、
/// プリアロケートした領域へ書き込む torrent など）を運んだときに起きる。
/// `FileOperationService` は更新日時とサイズ（`FileContentStamp`）で
/// これを検出しているが、**その検出は更新日時の精度に依存する**。
///
/// ## 更新日時に頼りきれない理由（実測）
///
/// | 形式 | 0.3 秒後・同じ大きさの書き換えを見分けられるか |
/// |---|---|
/// | APFS / HFS+ / exFAT | できる |
/// | FAT（msdos）| **できない**（ナノ秒が常に 0、精度 2 秒）|
/// | SMB（手元の NAS）| できた |
///
/// **NAS の OS は千差万別で、手元の 1 台で確かめられたことを一般化できない**
/// ［ユーザー指摘］。1 秒精度のサーバなら、同じ大きさのまま中身が入れ替わる
/// 書き込みを取り逃がす。取り逃がした先にあるのはデータ喪失なので、
/// **タイムスタンプにまったく依存しない確認**を重ねる。
///
/// ## どこまで確かめるか
/// 全体を読み直すと移動のたびに読み取りが 2 倍になる。抜き取り（先頭・中央・
/// 末尾）なら、大きさに関係なく一定のコストで、切り詰め・書き換えの大半を
/// 捕まえられる。**完全な保証ではない**が、「元を消してよいか」の判断を
/// 更新日時だけに委ねるよりはるかに堅い。
enum MoveVerification {
    /// 抜き取りで読む 1 窓のバイト数。
    private static let windowSize = 64 * 1024

    /// 運んだ結果が元と一致して見えるか。**一致しなければ元を消してはならない。**
    ///
    /// 判定できない場合（読めない等）は `true` を返す — ここで断ると、
    /// 確かめられないだけの正当な移動まで止めてしまう。検出は
    /// `FileContentStamp` の比較と併せて働く前提の、追加の網である。
    static func looksIdentical(source: URL, destination: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let values = try? source.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { return true } // リンク自体は運ぶだけ [SL-01]
        if values?.isDirectory == true {
            return treeSummary(of: source) == treeSummary(of: destination)
        }
        return fileLooksIdentical(source: source, destination: destination)
    }

    // MARK: - ファイル

    private static func fileLooksIdentical(source: URL, destination: URL) -> Bool {
        guard let sourceSize = size(of: source), let destinationSize = size(of: destination) else { return true }
        guard sourceSize == destinationSize else { return false }
        guard sourceSize > 0 else { return true }

        guard let a = try? FileHandle(forReadingFrom: source) else { return true }
        defer { try? a.close() }
        guard let b = try? FileHandle(forReadingFrom: destination) else { return true }
        defer { try? b.close() }

        for offset in sampleOffsets(for: sourceSize) {
            let left = read(a, at: offset)
            let right = read(b, at: offset)
            // どちらかが読めなければ判定を諦める（断らない側に倒す）。
            guard let left, let right else { return true }
            if left != right { return false }
        }
        return true
    }

    /// 先頭・中央・末尾。小さいファイルは 1 回で読み切れるので重複を除く。
    private static func sampleOffsets(for size: Int64) -> [UInt64] {
        guard size > Int64(windowSize) else { return [0] }
        let last = UInt64(max(size - Int64(windowSize), 0))
        let middle = UInt64(max(size / 2 - Int64(windowSize / 2), 0))
        return Array(Set([0, middle, last])).sorted()
    }

    private static func read(_ handle: FileHandle, at offset: UInt64) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: windowSize)
        } catch {
            return nil
        }
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    // MARK: - フォルダ

    /// フォルダは中身を読み直さず、**構成（件数と合計バイト数）**を突き合わせる。
    ///
    /// 木全体を抜き取り比較すると、大きなライブラリの移動で読み取りが
    /// 現実的でない量になる。件数と合計サイズなら追加の読み取りは要らず、
    /// 「運んでいる間に中身が増減した／大きさが変わった」は捕まえられる。
    /// **孫以下が同じ大きさのまま書き換わった場合は見分けられない**
    /// （既知の限界。フォルダの更新日時が動かないのと同じ理由）。
    private static func treeSummary(of url: URL) -> TreeSummary? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return nil }
        var summary = TreeSummary(count: 0, bytes: 0)
        while let child = enumerator.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            summary.count += 1
            summary.bytes += Int64(values?.fileSize ?? 0)
        }
        return summary
    }

    private struct TreeSummary: Equatable {
        var count: Int
        var bytes: Int64
    }
}
