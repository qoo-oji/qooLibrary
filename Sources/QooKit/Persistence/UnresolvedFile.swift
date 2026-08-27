//
//  未解決ファイル [AL-30〜AL-34][UR-01〜UR-06][15.6 節][§4.11]。
//
//  **「未解決」とは、どのファイル名フォーマットにも一致せず、埋め込み
//  メタデータも持たなかったファイル**のこと [EM-03]。ラベルが 1 つも
//  付かないので、ラベルフィルタからは辿り着けず蔵書の中に埋もれる
//  ——件数を知らせるだけでは片付けられないので、走査が**行として**記録し、
//  整理ウインドウで拾えるようにする [AL-31]。
//
//  ## 「見つからないファイル」（`state == .orphaned`）とは別物
//  あちらは**実体が見つからない**、こちらは**実体はあるが読めない**。
//  取り違えると片方の画面が意味を失うので、一覧は互いに相手を出さない。
//
import Foundation

/// 走査が観測した「未解決である」という判定 1 件 [AL-31]。
///
/// **観測した時点のファイル名を持ち回る。** 記録済みの名前と食い違えば、
/// 利用者が名前を直したということなので**無視フラグを解く**
/// ［ユーザー判断、2026-08］——無視は「この名前はどのフォーマットにも
/// 当てはまらないと判断した」という意味なので、名前が変われば前提が消える。
public struct UnresolvedObservation: Sendable, Hashable {
    public let fileID: FileID
    public let filename: String

    public init(fileID: FileID, filename: String) {
        self.fileID = fileID
        self.filename = filename
    }
}

/// 整理ウインドウが並べる未解決ファイル 1 件 [UR-01]。
public struct UnresolvedFile: Sendable, Hashable, Identifiable {
    public let row: FileRow
    /// 「以後無視する」[AL-33]。**行は残す** [UR2-04]——消すと次の走査で
    /// また未解決として現れ、無視した意味が無くなる。
    public let isIgnored: Bool
    /// 最初に未解決と判定した時刻。**名前が変わっても更新しない**
    /// ——「いつから片付いていないか」を表すため。
    public let detectedAt: Date
    /// ライブラリタイプの型条件を満たさなかったか [TY-01]。
    ///
    /// **未解決の理由ではない**（`libraryTypeMismatch` が真でも、別の
    /// フォーマットに一致すれば解決する）。一覧に印として出すだけ——
    /// 「なぜ当たらないか」の手がかりとしては強い。
    public let libraryTypeMismatch: Bool

    public var id: FileID { row.id }

    public init(row: FileRow, isIgnored: Bool, detectedAt: Date,
                libraryTypeMismatch: Bool) {
        self.row = row
        self.isIgnored = isIgnored
        self.detectedAt = detectedAt
        self.libraryTypeMismatch = libraryTypeMismatch
    }
}

/// ライブラリ 1 件ぶんの未解決の内訳 [AL-31][AL-33]。
///
/// **2 つに分けて持つ。** 「片付けるべき件数」と「無視した件数」は別のことで、
/// 混ぜると空状態の文言が嘘になる——無視しただけなのに「すべて一致しています」と
/// 言ってしまう（実機検証で見つけた）。
public struct UnresolvedCounts: Sendable, Hashable {
    /// 一覧に出る件数（無視したものを除く）。左ペインの「N 件」はこちら。
    public let pending: Int
    /// 「以後無視する」を立てたもの [AL-33]。
    public let ignored: Int

    public init(pending: Int, ignored: Int) {
        self.pending = pending
        self.ignored = ignored
    }
}

/// 再マッチングの結果 [AL-34]。
public struct RematchOutcome: Sendable, Hashable {
    /// 試した件数。
    public let attempted: Int
    /// 解決して一覧から消えた件数。
    public let resolved: Int
    /// 途中で打ち切られたか。**打ち切っても、そこまでの結果は保存する**
    /// ——収束型なので、次に走らせれば続きから片付く。
    public let cancelled: Bool

    public init(attempted: Int, resolved: Int, cancelled: Bool = false) {
        self.attempted = attempted
        self.resolved = resolved
        self.cancelled = cancelled
    }
}

/// 拡張子を除いたファイル名——**パーサへ渡す値**。
///
/// `FileSnapshot`（走査が観測したもの）と `FileRow`（DB に載っているもの）で
/// **同じ導出を使う**ために切り出してある。食い違うと「走査では未解決なのに
/// 再マッチングでは解決する（またはその逆）」という、画面からは理由の
/// 読み取れない形になる。
public enum FilenameStem {
    public static func of(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}
