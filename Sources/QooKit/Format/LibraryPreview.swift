//
//  設定を実ファイル名へ当てて結果を見せる [HP-05、ユーザー要望]。
//
//  **有効化のときに「その選択で何がどう変わるのか」を答えるための計算。**
//  テンプレートの中身（ラベルグループ名やフォーマットの一覧）を並べても、
//  自分の蔵書がどう解釈されるかは分からない——実際に当ててみせるのが唯一の答え。
//
//  ここは純粋関数だけを置く。ファイルの収集は上位層（`FileIO` 経由 [NV6-01]）。
//
import Foundation

public enum LibraryPreview {

    /// 1 ファイル分の結果。
    public struct Item: Sendable, Hashable, Identifiable {
        /// 一覧の安定した並びのための連番（入力順）。
        public let id: Int
        public let filename: String
        /// どのフォーマットにも一致しなかった [AL-31]。
        public var isUnresolved: Bool { fields.isEmpty && !matched }
        public let matched: Bool
        /// **型条件 [TY-01] に反したが警告に留めた**——`@librarytype` の値が
        /// このライブラリの型名と違う。取り込みはされるが、たいていは
        /// 型名の設定ミスなので目立たせる価値がある（実蔵書で 146 件が
        /// これに当たった実例がある）。
        public let libraryTypeMismatch: Bool
        public let fields: [Field]

        public struct Field: Sendable, Hashable {
            /// 表示名は UI 層が決める（`QooKit` は訳語を持たない [A-01]）。
            public let ref: FieldRef
            public let value: String
            public init(ref: FieldRef, value: String) {
                self.ref = ref
                self.value = value
            }
        }

        public init(id: Int, filename: String, matched: Bool,
                    libraryTypeMismatch: Bool, fields: [Field]) {
            self.id = id
            self.filename = filename
            self.matched = matched
            self.libraryTypeMismatch = libraryTypeMismatch
            self.fields = fields
        }
    }

    /// 走らせた結果のまとめ。
    public struct Outcome: Sendable, Hashable {
        /// 試した件数（対象拡張子で絞ったあと）。
        public let total: Int
        public let matched: Int
        public let unresolved: Int
        public let libraryTypeMismatched: Int
        /// 表示する明細。**未解決を先頭に集める**——調整が要るのはそこなので
        /// [ユーザー判断]。同じ区分の中では入力順を保つ。
        public let items: [Item]
        /// 対象拡張子でないため試さなかった件数 [AL-11][IF-01]。
        ///
        /// **これを出さないと「試した件数」が実際の走査と食い違って見える。**
        /// 実機で、プレビューが 12 件中 4 件未解決と出したのに走査は 3 件と
        /// 報告し、差の 1 件（`メモ.txt`）が何なのか分からなかった。
        public let excluded: Int
        /// 収集の上限に当たって打ち切ったか。
        public let truncated: Bool

        public var matchRate: Double { total == 0 ? 0 : Double(matched) / Double(total) }

        public init(total: Int, matched: Int, unresolved: Int, libraryTypeMismatched: Int,
                    excluded: Int = 0, items: [Item], truncated: Bool) {
            self.total = total
            self.matched = matched
            self.unresolved = unresolved
            self.libraryTypeMismatched = libraryTypeMismatched
            self.excluded = excluded
            self.items = items
            self.truncated = truncated
        }

        public static let empty = Outcome(total: 0, matched: 0, unresolved: 0,
                                          libraryTypeMismatched: 0, items: [], truncated: false)
    }

    /// 草案の設定でファイル名を解釈する [HP-05]。
    ///
    /// **保存を経由しない。** 編集中の草案をそのままコンパイルして試せることが
    /// この機能の値打ちで、「一度保存しないと結果が分からない」なら、
    /// 壊れた設定を保存させることになる。
    ///
    /// - Parameters:
    ///   - filenames: 拡張子つきでよい（パースの対象外なので落とす [4.8]）。
    ///   - displayLimit: 明細として返す上限。集計は全件について行う。
    public static func run(filenames: [String],
                           draft: LibrarySettingsDraft,
                           displayLimit: Int = 200,
                           truncated: Bool = false) -> Outcome {
        // 壊れたフォーマットは落として進む——編集の途中で壊れているのは
        // 普通の状態で、そこで打ち切るとプレビューが一切出せなくなる。
        let settings = draft.compiledSnapshot()
        let parser = FilenameParser()

        // **走査と同じ条件で絞る** [AL-11][IF-01]。絞らないと、対象外の
        // ファイル（`メモ.txt` など）まで「未解決」に数えてしまい、
        // 有効化した後の走査結果と数が合わない——実機でそうなった。
        // 空集合は「すべてが対象」の意味 [`LibraryEnumerator` の解釈]。
        let targets = Set(draft.targetExtensions.map { $0.lowercased() })
        let candidates = targets.isEmpty ? filenames : filenames.filter {
            targets.contains(($0 as NSString).pathExtension.lowercased())
        }
        let excluded = filenames.count - candidates.count

        var items: [Item] = []
        var matched = 0
        var unresolved = 0
        var mismatched = 0

        for (index, filename) in candidates.enumerated() {
            let stem = (filename as NSString).deletingPathExtension
            guard let result = parser.parse(stem, settings: settings, purpose: .preview) else {
                unresolved += 1
                items.append(Item(id: index, filename: filename, matched: false,
                                  libraryTypeMismatch: false, fields: []))
                continue
            }
            matched += 1
            if result.libraryTypeMismatch { mismatched += 1 }

            let parsed = FieldPostProcessor.postProcess(result, settings: settings)
            var fields: [Item.Field] = []

            // **記録される値を出す。** 切り出したフィールドをそのまま並べる
            // だけでは足りない——シリーズ名と巻数は `@title` から導出される
            // ことが多く [SE-02][RW-10]、そこまで見せないと「タイトルに
            // 巻数が残っているのはなぜか」が分からない。
            if let title = parsed.title, !title.isEmpty {
                fields.append(Item.Field(ref: .title, value: title))
            }
            // **意味束縛 [RW-13] で同じ値がラベルにも流れるものは 1 回だけ出す**
            // ［ユーザー指摘: 「著者名」と「著者」が別々に出るが同じもののはず］。
            // ラベル側（グループ名で出る）を残す——利用者に見える分類の軸は
            // フィールド（グループ）だから。束縛が無い・値が流れていない場合は
            // 従来どおりフィールドとして出す。
            func flowsIntoLabels(_ keyword: SemanticKeyword, value: String) -> Bool {
                guard let group = draft.semanticBindings[keyword] else { return false }
                return parsed.labelValues[group]?.contains(value) ?? false
            }
            if let series = parsed.seriesName, !series.isEmpty,
               !flowsIntoLabels(.series, value: series) {
                fields.append(Item.Field(ref: .series, value: series))
            }
            if parsed.volume.kind != .none {
                fields.append(Item.Field(ref: .volume, value: parsed.volume.raw ?? ""))
            }
            if let author = parsed.authorName, !author.isEmpty,
               !flowsIntoLabels(.author, value: author) {
                fields.append(Item.Field(ref: .author, value: author))
            }
            // ラベルは**実際に付く値**を出す。予約語の束縛 [RW-13] を畳んだ
            // 後の姿なので、`@author` がフィールドへ流れる設定でも正しく出る。
            //
            // **束縛先のフィールド番号ではなく予約語で表す。** `@labelgroupN` を
            // 撤去した [v3 ステージ 5] ので `FieldRef` に番号を表す case は無く、
            // またフィールドへ値が流れる経路は意味予約語だけになった。表示側は
            // 予約語から束縛先のフィールド名と色を引ける。
            for (group, values) in parsed.labelValues.sorted(by: { $0.key < $1.key }) {
                guard let keyword = SemanticKeyword.allCases
                    .first(where: { draft.semanticBindings[$0] == group }) else { continue }
                for value in values where !value.isEmpty {
                    fields.append(Item.Field(ref: keyword.fieldRef, value: value))
                }
            }
            items.append(Item(id: index, filename: filename, matched: true,
                              libraryTypeMismatch: result.libraryTypeMismatch, fields: fields))
        }

        // 未解決 → 型不一致 → 一致 の順。同じ区分では入力順を保つ。
        let ordered = items.sorted { a, b in
            func rank(_ item: Item) -> Int {
                if !item.matched { return 0 }
                if item.libraryTypeMismatch { return 1 }
                return 2
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra == rb ? a.id < b.id : ra < rb
        }

        return Outcome(total: candidates.count, matched: matched, unresolved: unresolved,
                       libraryTypeMismatched: mismatched, excluded: excluded,
                       items: Array(ordered.prefix(displayLimit)), truncated: truncated)
    }
}
