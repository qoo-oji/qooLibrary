//
//  シェルフ — 保存した絞り込み [SH-01〜SH-10][19章 §19.2]。
//
//  **StackNest のスマートシェルフの簡易形**。左ペインでよく使う絞り込みを名前を
//  付けて覚えておき、ワンクリックで戻す。ライブラリ単位の永続設定で、
//  **全ウインドウ共有** [ST-23]——ピン留めやフィールドの並び順と同じ扱い。
//  復元した結果（どのラベルにチェックが入っているか）のほうはウインドウ固有
//  [ST-20] で、これは「設定を共有し、適用状態は共有しない」という既存の分け方
//  そのままである。
//
//  ## ラベルは行 ID で覚える [SH-05]
//  名前で覚えると改名 [LB-06] で壊れ、ID で覚えると削除でぶら下がる——という
//  古典的な二択だが、このコードベースでは **ID のほうが明確に有利**:
//  `label.id` は AUTOINCREMENT で再利用されず、削除を ⌘Z で戻すと**同じ ID**
//  へ復元される [LabelSnapshot]。ID で持てば、ラベルを消して取り消した後も
//  シェルフの条件が生き返る。名前で持つとその往復に耐えられない。
//
//  **解決できない ID は読み込み時に黙って落とす。** 行を消したり非表示にしたり
//  [LA3-01] しても、シェルフ側の記録は残す——消してしまうと上の ⌘Z 復活が
//  できなくなる。「画面でチェックが付いているものだけが効いている」という
//  見え方は保たれる。
//
import Foundation

/// シェルフが覚えている絞り込み [SH-02]。
///
/// **中身は `FileQuery` の語彙で持つ**——中央ペインへ渡すときに変換を挟まない。
public struct ShelfCondition: Codable, Sendable, Hashable {
    /// 選んでいたラベル [LF-08〜LF-10]。**グループごとの入れ子にせず平らに持つ**
    /// ——ラベルはグループをまたいで移動しない [LB-07] ので、読み込み時に
    /// 実際の所属から組み直せる。入れ子で持つと、グループの行 ID という
    /// 2 つ目のぶら下がり得る参照を抱えることになる。
    public var labelIDs: [LabelID]
    public var rating: FileQuery.RatingFilter?
    /// ⌘F の検索語 [SR-03]。空文字は `nil` に畳む。
    public var searchText: String?
    /// 並べ替え [VM-15]。
    public var sort: FileQuery.SortSpec
    /// 表示モード [VM-10]。**今は必ず `.libraryFlat`**——シェルフはライブラリ
    /// 表示モードでしか出さない [SH-09] ので、フォルダ表示で保存される経路が
    /// 無い。それでも保存して復元時に適用するのは、復元をこの値だけで
    /// 完結させておくため（別の入口が増えても、そこが表示モードの切り替えを
    /// 覚えている必要がない）。
    public var displayMode: FileQuery.DisplayMode

    public init(labelIDs: [LabelID],
                rating: FileQuery.RatingFilter? = nil,
                searchText: String? = nil,
                sort: FileQuery.SortSpec = .byFilename,
                displayMode: FileQuery.DisplayMode = .libraryFlat) {
        // **並びを正規化する**——`Hashable` の一致（＝いま表示中の絞り込みが
        // どのシェルフと同じかの判定 [SH-08]）を、選んだ順序に左右させない。
        // 保存する JSON も決定的になる。
        self.labelIDs = labelIDs.sorted { $0.rawValue < $1.rawValue }
        self.rating = rating
        let trimmed = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchText = (trimmed?.isEmpty == false) ? trimmed : nil
        self.sort = sort
        self.displayMode = displayMode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(labelIDs: try c.decodeIfPresent([LabelID].self, forKey: .labelIDs) ?? [],
                  rating: try c.decodeIfPresent(FileQuery.RatingFilter.self, forKey: .rating),
                  searchText: try c.decodeIfPresent(String.self, forKey: .searchText),
                  sort: try c.decodeIfPresent(FileQuery.SortSpec.self, forKey: .sort) ?? .byFilename,
                  displayMode: try c.decodeIfPresent(FileQuery.DisplayMode.self,
                                                     forKey: .displayMode) ?? .libraryFlat)
    }

    /// 条件が 1 つでも入っているか [SH-07]。**空のシェルフは作らせない**
    /// ——押しても何も絞られないものを一覧に並べても、利用者は「効かない
    /// シェルフ」としか読めない（RA-05 で「効果があるときだけ出す」とした
    /// のと同じ判断）。並べ替えと表示モードは絞り込みではないので数えない。
    public var isActive: Bool {
        !labelIDs.isEmpty || rating != nil || searchText != nil
    }

    /// 平らな ID を、実際の所属でグループごとに組み直す [LF-08]。
    ///
    /// - Parameter groupOf: いま画面に出ているラベルの所属。**ここに無い ID は
    ///   落とす**——消えたラベル・非表示のラベル [LA3-05] を条件に残すと、
    ///   画面のチェックに現れない絞り込みが効いてしまい、件数が合わない理由を
    ///   利用者が読み取れない。
    public func groupedSelection(
        groupOf: (LabelID) -> LabelGroupID?
    ) -> [LabelGroupID: Set<LabelID>] {
        var result: [LabelGroupID: Set<LabelID>] = [:]
        for id in labelIDs {
            guard let group = groupOf(id) else { continue }
            result[group, default: []].insert(id)
        }
        return result
    }

    /// **いま解決できるラベルだけに畳んだ写し** [SH-08]。
    ///
    /// 一致判定（いまの絞り込みと同じシェルフか）に使う。畳まずに比べると、
    /// 非表示になったラベル [LA3-05] を 1 つ含むシェルフが**二度と一致しなく
    /// なる**——復元しても選択にはそのラベルが入らないので、条件は永久に
    /// 食い違ったままになる［code-review の指摘］。
    ///
    /// **記録そのものは畳まない**（`labelIDs` は保持したまま）。畳んで保存し
    /// 直すと、ラベル削除の ⌘Z で生き返る性質 [SH-05] を失う。
    public func keepingResolvableLabels(groupOf: (LabelID) -> LabelGroupID?) -> ShelfCondition {
        ShelfCondition(labelIDs: labelIDs.filter { groupOf($0) != nil },
                       rating: rating, searchText: searchText,
                       sort: sort, displayMode: displayMode)
    }

    /// グループごとの選択から作る（保存時）。
    public static func from(selection: [LabelGroupID: Set<LabelID>],
                            rating: FileQuery.RatingFilter?,
                            searchText: String?,
                            sort: FileQuery.SortSpec,
                            displayMode: FileQuery.DisplayMode) -> ShelfCondition {
        ShelfCondition(labelIDs: selection.values.flatMap { $0 },
                       rating: rating, searchText: searchText,
                       sort: sort, displayMode: displayMode)
    }
}

/// シェルフ 1 件 [SH-01]。
public struct ShelfSummary: Sendable, Hashable, Identifiable {
    public let id: ShelfID
    public let libraryID: LibraryID
    public var name: String
    /// 並び順 [SH-10]。渡された順に 0 から振り直す。
    public var displayOrder: Int
    public var condition: ShelfCondition

    public init(id: ShelfID, libraryID: LibraryID, name: String,
                displayOrder: Int, condition: ShelfCondition) {
        self.id = id
        self.libraryID = libraryID
        self.name = name
        self.displayOrder = displayOrder
        self.condition = condition
    }
}
