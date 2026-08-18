//
//  既定値の集約 [4章 命名規約: マジックナンバー直書き禁止]。
//
//  `AppLimits` が「これ以上は許さない」上限を持つのに対し、こちらは
//  「何も指定されなければこう振る舞う」既定値を持つ。
//
import Foundation

public enum AppDefaults {

    public enum Library {
        /// 新規ライブラリの対象拡張子 [要件定義書 11.4 節:
        /// 「対象拡張子は全テンプレート共通で `zip, cbz, rar, cbr, 7z, cb7,
        /// pdf, epub`」][AL-11][IF-01]。
        ///
        /// **空集合を既定にしてはならない。** `LibraryEnumerator` は空を
        /// 「拡張子で絞らない＝すべてのファイルが対象」と解釈するため、
        /// 空のまま登録すると `.DS_Store` やメモの `.txt` まで蔵書として
        /// 取り込む。ブックフォルダの判定 [IF-01] も「直下に対象拡張子
        /// ファイルが 0 件」を条件にするので、空だと画像フォルダが
        /// 1 冊と見なされなくなる——**空は「既定」ではなく別の意味を持つ**。
        public static let targetExtensions: Set<String> = [
            "zip", "cbz", "rar", "cbr", "7z", "cb7", "pdf", "epub",
        ]
    }
}
