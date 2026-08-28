//
//  重複グループと、その中の 1 件を選ぶ規則 [DU-05][DU-08][DU-25]。
//
//  **どちらの規則も純粋関数として置く。** 代表の決定 [DU-05] は一覧の
//  表示（SQL の窓関数）と比較ビューの両方から要り、残す 1 件の決定 [DU-25] は
//  「実行前にプレビューして行ごとに上書きできる」[DU-26] ため、**判断と
//  実行を分けられる形**でなければならない。
//
import Foundation

/// 同じ作品とみなされたファイルの組。
public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    /// 判定キー [DU-02]。`DuplicateGroupKey.make` が作る値。
    public let id: String
    /// 代表ファイル [DU-05][DU-08]。必ず `members` に含まれる。
    public let representative: FileID
    /// 表示順（＝代表の決定順）で並んだ全メンバー。
    public let members: [FileID]

    public var count: Int { members.count }

    public init(id: String, representative: FileID, members: [FileID]) {
        self.id = id
        self.representative = representative
        self.members = members
    }
}

/// 一括で「残す 1 件」を選ぶ規則 [DU-25]。
public enum KeepRule: Sendable, Hashable, CaseIterable {
    case largestSize
    case mostPages
    case highestResolution
    case highestRating
    /// 形式の優先順（例: `["cbz", "zip", "pdf"]`）。先頭ほど優先。
    case preferFormats([String])

    public static var allCases: [KeepRule] {
        [.largestSize, .mostPages, .highestResolution, .highestRating,
         .preferFormats(AppDefaults.Duplicates.formatPreference)]
    }
}

public enum DuplicateSelection {

    // MARK: - 代表の決定 [DU-05][DU-08]

    /// 表示順に並べ替える。**先頭が代表**になる。
    ///
    /// ①評価が高いもの ②サイズが大きいもの ③ファイル名の自然順で先頭
    /// [DU-05]。手動のピン留め [DU-08] は撤回した [§19.8]——代表は自動選定に
    /// 任せ、残す 1 冊は比較ビューで選べば足りる［ユーザー判断］。
    ///
    /// **③まで同点になることはある**（同じ名前のファイルは同じフォルダには
    /// 置けないが、別のフォルダになら置ける）。そのときは `id` で決める
    /// ——順序が実行のたびに変わると、代表が理由なく入れ替わって見える。
    public static func inRepresentativeOrder(_ rows: [FileRow]) -> [FileRow] {
        rows.sorted(by: precedes)
    }

    /// 代表を 1 件選ぶ。`rows` が空なら `nil`。
    public static func representative(of rows: [FileRow]) -> FileRow? {
        inRepresentativeOrder(rows).first
    }

    static func precedes(_ a: FileRow, _ b: FileRow) -> Bool {
        if a.rating != b.rating { return a.rating > b.rating }  // [DU-05]①
        if a.fileSize != b.fileSize { return a.fileSize > b.fileSize } // ②
        let byName = a.filename.localizedStandardCompare(b.filename)   // ③ 自然順
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id.rawValue < b.id.rawValue
    }

    // MARK: - 残す 1 件の決定 [DU-25]

    /// 規則を当てて「残す 1 件」を選ぶ。
    ///
    /// **どの規則でも同点になりうる**ので、決まらなかったぶんは代表の順序
    /// [DU-05] へ落とす——規則ごとに別の tie-break を持たせると、
    /// 「サイズ最大」と「評価最高」で同じ組から違う順に並んで見える。
    ///
    /// `mostPages` / `highestResolution` は**まだ数えていない**（`nil`）ものを
    /// 最下位に置く [DU-22]。全件が `nil` なら規則は何も決めず、代表と同じ
    /// 1 件になる——**取得できていない値で勝たせない。**
    public static func keep(_ rule: KeepRule, from rows: [FileRow]) -> FileRow? {
        guard !rows.isEmpty else { return nil }
        let ordered = inRepresentativeOrder(rows)
        return ordered.max(by: { score(rule, $0) < score(rule, $1) })
            .flatMap { best in
                // `max(by:)` は同点のとき**後ろ**を返す。代表順の先頭を採りたい
                // ので、最高得点の中から改めて先頭を取り直す。
                let top = score(rule, best)
                return ordered.first { score(rule, $0) == top }
            }
    }

    /// 規則ごとの得点。大きいほど「残す」に近い。
    static func score(_ rule: KeepRule, _ row: FileRow) -> Double {
        switch rule {
        case .largestSize:
            return Double(row.fileSize)
        case .mostPages:
            return row.pageCount.map(Double.init) ?? -1
        case .highestResolution:
            guard let w = row.firstImageWidth, let h = row.firstImageHeight else { return -1 }
            return Double(w) * Double(h)
        case .highestRating:
            return Double(row.rating)
        case .preferFormats(let order):
            let ext = (row.filename as NSString).pathExtension.lowercased()
            // 一覧に無い形式は最下位。**同点にしない**——「cbz を優先」と
            // 指定したのに、一覧に無い形式どうしが名前順で決まるほうが読める。
            guard let i = order.firstIndex(where: { $0.lowercased() == ext }) else { return -1 }
            return Double(order.count - i)
        }
    }
}
