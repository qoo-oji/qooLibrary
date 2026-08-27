//
//  自動走査の「知らせるだけ」の結果を、同じ内容で繰り返し履歴へ落とさない
//  ための番人 [NT-01][OR2-05][UR2-02][NT-07]。
//
//  **`ScanSummary` の件数は差分ではない**［レビューで発見］。`unresolvedNames` は
//  「この走査で見て未解決だったファイル」を数え、`orphaned` は「この走査の
//  範囲で見つからなかった行」を数える——どちらも**新しく起きた件数ではない**。
//  したがって、恒久的に未解決なファイルを 1 つ含むフォルダは、そこへ何か
//  変更があるたびに差分走査が走り、毎回まったく同じ「未解決 1 件」を返す。
//  素直に履歴へ落とすと、外部でファイルを整理するだけで**保持上限
//  1,000 件 [NT-07] を数十回の操作で使い切る**。
//
//  ## なぜ「前回記録した内容」ではなく「前回観測した内容」と比べるのか
//  前者だと**直った後に同じ件数で再発したときに黙る**——(1) → (0) → (1) と
//  変化した場合、最後に記録したのは (1) なので 3 度目が握り潰される。
//  観測そのものを覚えれば、(0) を挟んだ時点で前提が変わったと分かる。
//
import Foundation
import Observation
import QooKit

@MainActor
public final class ScanFindingsDigest {

    /// 「知らせるだけ」の 3 つ [ID-06][AL-31][IF-05]。
    /// **判断が要るもの（差し替え [ID-05]・巻数 [EM-30]）は含めない**
    /// ——あちらは割り込んで確認を取るので、まとめて黙らせてはならない。
    public struct Findings: Sendable, Equatable {
        public var orphaned: Int
        public var unresolved: Int
        public var bookFoldersReleased: Int

        public init(orphaned: Int, unresolved: Int, bookFoldersReleased: Int) {
            self.orphaned = orphaned
            self.unresolved = unresolved
            self.bookFoldersReleased = bookFoldersReleased
        }

        public var isEmpty: Bool {
            orphaned == 0 && unresolved == 0 && bookFoldersReleased == 0
        }
    }

    private var lastObserved: [LibraryID: Findings] = [:]

    public init() {}

    /// 履歴へ落とすべきか。
    ///
    /// **観測は毎回覚える**（記録したかどうかに関わらず）。空の観測を覚えるのが
    /// 要点で、それが「いったん片付いた」という区切りになる。
    public func shouldRecord(_ findings: Findings, for libraryID: LibraryID) -> Bool {
        defer { lastObserved[libraryID] = findings }
        guard lastObserved[libraryID] != findings else { return false }
        return !findings.isEmpty
    }

    /// ライブラリが消えた（無効化・登録解除）ときに忘れる。**残しておくと、
    /// 同じフォルダを登録し直したときに 1 回目が黙る**——行 ID は
    /// `AUTOINCREMENT` なので同じ値が戻ってくることは無いが、辞書が
    /// 際限なく伸びるのも避けたい。
    public func forget(_ libraryID: LibraryID) {
        lastObserved.removeValue(forKey: libraryID)
    }
}
