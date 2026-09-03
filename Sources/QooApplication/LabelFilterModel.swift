//
//  ラベルフィルタの状態 [LF-01〜LF-14][PN-01〜PN-06][RT-01〜RT-03]。
//
//  **選択はウインドウ固有状態** [ST-20][ST-21][LF-06]——DB に保存せず、ウインドウ
//  ごとに独立する。一方で**ピン留めとフィールドの並び順はライブラリ単位の永続設定**
//  で全ウインドウ共有 [ST-23][PN-04][LG-07]。同じ 1 つの画面に「ウインドウごと」と
//  「全ウインドウ共有」が同居するので、どちらなのかを取り違えないこと。
//
import Foundation
import Observation
import QooInfrastructure
import QooKit

/// 左ペイン下半分の状態。`WindowState` が 1 つ持つ。
///
/// ## 中央ペインへの効かせ方
/// DB の一覧をそのまま描くのではなく、**実体の一覧を絞る**形にしてある
/// （``allowedChildNames``）。フォルダ表示モードではすべてのファイル操作が
/// 可能でなければならず [VM-03]、フィルタが全 OFF なら DB に載っていないもの
/// （対象拡張子以外）も従来どおり見える必要がある [VM-01] ため。
@MainActor
@Observable
public final class LabelFilterModel {
    // MARK: - 対象

    /// 表示中のライブラリ。`nil` ならフィルタは出さない [LF-01]。
    public private(set) var library: LibrarySummary?

    /// 並べる順に整えたフィールド [LF-01][LF-03]。**見えるラベルが 1 件も無い
    /// フィールドは含まない** [LF-02][LG-05][LA3-05]。
    public private(set) var fields: [FieldSummary] = []

    /// フィールドごとのラベル [LF-04]。**非表示のものは含まない** [LA3-05]
    /// ——手動で隠したもの [LA3-02] と、生きている実体が 1 件も無いもの [LA3-01]。
    public private(set) var labels: [FieldID: [LabelSummary]] = [:]

    // MARK: - 選択（ウインドウ固有）

    /// フィールド内 OR × フィールド間 AND [LF-08〜LF-10]。初期状態は全 OFF [LF-06]。
    public private(set) var selection: [FieldID: Set<LabelID>] = [:]

    /// 評価フィルタ [RT-01〜RT-03]。ラベルフィルタと AND [RT-02]。
    public var ratingFilter: FileQuery.RatingFilter? {
        didSet { if ratingFilter != oldValue { bumpRevision() } }
    }

    /// 展開しているフィールド [LF-04]。
    public var expandedFields: Set<FieldID> = []

    /// 「もっと見る」で全ラベルを出しているフィールド [PN-02][PN-05]。
    public var revealedFields: Set<FieldID> = []

    /// 「もっと見る」の中のインクリメンタル検索 [PN-05]。
    public var searchText: [FieldID: String] = [:]

    // MARK: - 結果

    /// 条件に該当する件数 [LF-11]。**ライブラリ全体**に対する件数で、今いる
    /// フォルダの件数ではない——フィルタは「このライブラリの中で何件が条件に
    /// 合うか」を答えるもので、フォルダを移動するたびに数字が変わると
    /// 「絞り込みが効いているか」の手がかりにならない。
    public private(set) var matchedCount: Int?

    /// フィルタ全 OFF のときのライブラリ全体の件数。分母として出す [LF-11]。
    public private(set) var totalCount: Int?
    /// 未整理のファイルの件数 [UR3-01]。左ペイン最下部の常設項目に出す。
    ///
    /// **ラベルフィルタと同じ読み込みに相乗りしている**——どちらも
    /// 「表示中のライブラリについて、左ペインが出すもの」で、駆動する鍵
    /// （`labelFilterLoadKey`）も同じでよい。専用のモデルを足すと、走査・⌘Z の
    /// たびに読み直す配線をもう 1 組持つことになる。
    public private(set) var unresolvedCounts: UnresolvedCounts?

    /// 中央ペインが残してよい子の名前 [VM-02]。`nil` は「絞らない」。
    public private(set) var allowedChildNames: Set<String>?

    /// 最後に読み込みへ失敗した理由。UI が黙って空を見せないため [ER-01]。
    public private(set) var loadFailure: String?

    // MARK: - 変化の通知

    /// 選択・評価が変わるたびに増える。`MainWindowView` の `.task(id:)` が
    /// これを鍵に再計算する——選択そのものを鍵にすると、辞書の中身が同じでも
    /// 別インスタンスになった瞬間に再計算が走る。
    public private(set) var revision = 0

    private func bumpRevision() { revision &+= 1 }

    public init() {}

    // MARK: - 問い合わせ

    /// 何か 1 つでも条件が入っているか。
    public var isActive: Bool {
        ratingFilter != nil || selection.values.contains { !$0.isEmpty }
    }

    public func isSelected(_ label: LabelSummary) -> Bool {
        selection[label.fieldID]?.contains(label.id) == true
    }

    /// 選んだラベルの総数。見出しのバッジに出す。
    public var selectedLabelCount: Int {
        selection.values.reduce(0) { $0 + $1.count }
    }

    /// そのフィールドで実際に並べるラベル [PN-02][PN-03][PN-06]。
    ///
    /// 並べ方そのものは `PinnedLabelListing` が持つ——右ペインのラベル設定
    /// [RL-04] が「ラベルフィルタと同様に」同じ一覧を出すので、規則を 2 箇所に
    /// 置かない。ここが渡すのは「チェック中のものは必ず含める」[PN-06] だけ。
    public func visibleLabels(in field: FieldSummary) -> [LabelSummary] {
        PinnedLabelListing.visible(
            labels[field.id] ?? [],
            collapsedLimit: AppLimits.LabelFilter.collapsedLabelCount,
            isRevealed: revealedFields.contains(field.id),
            searchText: searchText[field.id] ?? "",
            mustInclude: { self.isSelected($0) })
    }

    /// 「もっと見る」を出すべきか [PN-02][PN-03]。
    public func hasMoreLabels(in field: FieldSummary) -> Bool {
        PinnedLabelListing.hasMore(
            labels[field.id] ?? [],
            collapsedLimit: AppLimits.LabelFilter.collapsedLabelCount,
            isRevealed: revealedFields.contains(field.id),
            mustInclude: { self.isSelected($0) })
    }

    // MARK: - 操作

    public func toggle(_ label: LabelSummary) {
        var set = selection[label.fieldID] ?? []
        if set.contains(label.id) { set.remove(label.id) } else { set.insert(label.id) }
        if set.isEmpty { selection[label.fieldID] = nil } else { selection[label.fieldID] = set }
        bumpRevision()
    }

    /// 一括 OFF [LF-07]。評価フィルタも一緒に落とす——「フィルタを解除する」
    /// つもりで押した利用者に、星だけ残っている状態を渡さない。
    public func clearAll() {
        guard isActive else { return }
        selection.removeAll()
        ratingFilter = nil          // didSet が revision を上げる
        bumpRevision()
    }

    /// シェルフの条件を適用する [SH-06]。
    ///
    /// **解決できないラベルは黙って落ちる** [SH-05]——消えた・非表示になった
    /// [LA3-05] ラベルは画面のチェックに現れないので、条件にだけ残すと
    /// 「なぜこの件数なのか」を利用者が読み取れなくなる。
    ///
    /// 選択のあるフィールドは**開いた状態にする**——チェックが入ったのに
    /// 畳まれたままだと、何が効いているのか確かめようがない。
    public func apply(_ condition: ShelfCondition) {
        selection = condition.selectionByField { fieldOf[$0] }
        expandedFields.formUnion(selection.keys)
        ratingFilter = condition.rating          // didSet が revision を上げる
        bumpRevision()
    }

    /// いま画面に出ているラベルの所属 [SH-05]。**解決の規則を 1 箇所に置く**
    /// ——`apply` と一致判定 [SH-08] が別々に組み立てると、片方だけ直したときに
    /// 「復元はできるのに一致しない」形でずれる。
    public var fieldOf: [LabelID: FieldID] {
        var result: [LabelID: FieldID] = [:]
        for (field, items) in labels {
            for label in items { result[label.id] = field }
        }
        return result
    }

    /// いま解決できるラベルだけに畳んだ写し [SH-08]。一致判定に使う。
    public func resolvable(_ condition: ShelfCondition) -> ShelfCondition {
        let map = fieldOf
        return condition.keepingResolvableLabels { map[$0] }
    }

    /// いまの選択と評価から条件を作る（保存・上書き保存・照合に使う）[SH-01]。
    ///
    /// **並び順・検索語・表示モードは引数で受ける**——このモデルは持っておらず、
    /// 写しを作ると正が 2 つになる（`ShelfModel` の型コメント参照）。
    public func currentCondition(searchText: String?,
                                 sort: FileQuery.SortSpec,
                                 displayMode: FileQuery.DisplayMode) -> ShelfCondition {
        ShelfCondition.from(selection: selection, rating: ratingFilter,
                            searchText: searchText, sort: sort, displayMode: displayMode)
    }

    /// ライブラリを切り替えたら選択をリセットする [ST-26]。
    private func resetSelection() {
        selection.removeAll()
        expandedFields.removeAll()
        revealedFields.removeAll()
        searchText.removeAll()
        if ratingFilter != nil { ratingFilter = nil }
        allowedChildNames = nil
        matchedCount = nil
        bumpRevision()
    }

    // MARK: - 読み込み

    /// 表示中のフォルダに対応するライブラリを解決し、フィールドとラベルを読む
    /// [LF-01][LF-02]。
    ///
    /// - Parameter registrationUUID: 現在のタブが**登録フォルダ経由**で開かれて
    ///   いるならその登録 ID、ボリューム経由なら `nil`。**URL から逆算しない**
    ///   ——ボリューム側のツリーを辿って同じ実フォルダに来た場合はライブラリと
    ///   して扱わない、という `NavigationRoot` の約束に従う（判定は呼び出し側の
    ///   責務で、この型へ `URL` を渡す API は用意しない）。
    public func load(registrationUUID: UUID?, services: LibraryServices) async {
        let resolved = registrationUUID.flatMap { services.library(registrationUUID: $0) }
        if resolved?.id != library?.id { resetSelection() }
        library = resolved
        guard let library = resolved else {
            fields = []
            labels = [:]
            totalCount = nil
            unresolvedCounts = nil
            loadFailure = nil
            return
        }
        do {
            let all = try await services.fields(libraryID: library.id)
            // **フィルタに出すのは「見えるラベル」だけ** [LA3-05]——手動で
            // 隠したもの [LA3-02] と、生きている実体が 1 件も無いもの [LA3-01]。
            // 後者は導出なので、実体が戻れば次の読み直しで自然に復帰する。
            //
            // **フィールドの出し分けを `labelCount` で先に決めない**——あの値は
            // 非表示のラベルも数える（フィールド編集ウインドウのため）。
            // 読んでから絞り、空になったフィールドを落とす [LF-02][LG-05]。
            var loaded: [FieldID: [LabelSummary]] = [:]
            for field in all where field.labelCount > 0 {
                let visible = try await Self.visibleLabels(in: field.id, services: services)
                if !visible.isEmpty { loaded[field.id] = visible }
            }
            fields = all.filter { loaded[$0.id] != nil }
            labels = loaded
            pruneSelectionToVisibleLabels()
            totalCount = try await services.fileCount(FileQuery(libraryID: library.id))
            unresolvedCounts = try await services.unresolvedFileCounts()[library.id]
            loadFailure = nil
        } catch {
            fields = []
            labels = [:]
            unresolvedCounts = nil
            loadFailure = String(describing: error)
            Log.ui.warning("ラベルフィルタを読めない: \(String(describing: error))")
        }
    }

    /// 件数と、中央ペインが残す子の名前を計算し直す [LF-11][VM-02]。
    public func refreshResults(folderRelativePath: String?,
                               services: LibraryServices) async {
        guard let library, isActive else {
            allowedChildNames = nil
            matchedCount = nil
            return
        }
        var q = FileQuery(libraryID: library.id)
        q.labelSelection = selection.filter { !$0.value.isEmpty }
        q.ratingFilter = ratingFilter
        do {
            matchedCount = try await services.fileCount(q)
            if let path = folderRelativePath {
                q.scope = .folder(path: path, recursive: true)
                allowedChildNames = try await services.matchingChildNames(q)
            } else {
                // ライブラリの外を見ている間は絞らない。
                allowedChildNames = nil
            }
        } catch {
            // **絞れなかったときは絞らない**［設計判断］。問い合わせに失敗した
            // ことを理由に一覧を空にすると、利用者からはファイルが消えたように
            // しか見えない。件数だけを伏せる。
            allowedChildNames = nil
            matchedCount = nil
            Log.ui.warning("ラベルフィルタの件数を数えられない: \(String(describing: error))")
        }
    }

    /// 再帰検索の結果へフィルタを効かせる [LF-14]。
    ///
    /// 返すのは**残してよい URL**。`nil` は「絞らない」——フィルタ全 OFF、
    /// ライブラリの外、問い合わせ失敗のいずれか。`refreshResults` と同じく
    /// **失敗しても絞らない側に倒す**（一覧が黙って空になるより、フィルタが
    /// 効かないほうがまだ気づける）。
    ///
    /// - Parameter libraryRootPath: 解決済みのライブラリ根。DB の
    ///   `relativePath` はここを剥がした綴りで入っている。
    public func deepMatches(_ urls: [URL], libraryRootPath: String,
                            services: LibraryServices) async -> Set<URL>? {
        guard let library, isActive, !urls.isEmpty else { return nil }
        var byPath: [String: URL] = [:]
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(libraryRootPath + "/") else { continue }
            byPath[String(path.dropFirst(libraryRootPath.count + 1))] = url
        }
        guard !byPath.isEmpty else { return [] }
        var q = FileQuery(libraryID: library.id)
        q.labelSelection = selection.filter { !$0.value.isEmpty }
        q.ratingFilter = ratingFilter
        do {
            let matched = try await services.matchingRelativePaths(q, among: Array(byPath.keys))
            return Set(matched.compactMap { byPath[$0] })
        } catch {
            Log.ui.warning("検索結果を絞れない: \(String(describing: error))")
            return nil
        }
    }

    /// ピン留め [PN-04]。全ウインドウ共有の永続設定なので、書き込んだあと
    /// 手元の一覧も並べ直す（`labels` はピン留め優先の順で来る）。
    ///
    /// **読み直しも `visibleLabels` を通す** [LA3-05]［code-review の指摘］。
    /// リポジトリは非表示のものも返す [LA3-03] ので、素で入れ直すと
    /// **ピンを 1 つ切り替えただけでフィルタに非表示のラベルが並ぶ。**
    /// しかも `setLabelPinned` は世代番号を進めないため、次の走査まで直らない。
    public func setPinned(_ label: LabelSummary, _ pinned: Bool,
                          services: LibraryServices) async {
        do {
            try await services.setLabelPinned(label.id, pinned)
            labels[label.fieldID] = try await Self.visibleLabels(in: label.fieldID,
                                                                services: services)
            pruneSelectionToVisibleLabels()
        } catch {
            Log.ui.warning("ピン留めを保存できない: \(String(describing: error))")
        }
    }

    /// **フィルタに出すラベルを決める唯一の場所** [LA3-05]。
    ///
    /// リポジトリは非表示のものも返す [LA3-03]——出し分けは呼び出し側の都合
    /// なので、その判断をこの型の中で 2 度書かない（読み直す経路が
    /// `load` と `setPinned` の 2 つあり、片方だけ絞る形を実際に作った）。
    private static func visibleLabels(in fieldID: FieldID,
                                      services: LibraryServices) async throws -> [LabelSummary] {
        try await services.labels(fieldID: fieldID).filter(\.isVisible)
    }

    /// 一覧から消えたラベルのチェックを落とす [LA3-01][LF-05]。
    ///
    /// **これが無いと、絞り込みが効いたまま外す手段が消える**
    /// ［code-review の指摘］。チェック中のラベルの実体が全部ゴミ箱・保管庫へ
    /// 行くと、そのラベルは一覧から消える [LA3-01] のに `labelSelection` には
    /// 残るので、**中央ペインが空になったまま、原因のチェックボックスが
    /// どこにも見えない**——⇧⌘K で全部落とすしか手が無くなる。
    /// `PinnedLabelListing` の `mustInclude` [PN-06] では救えない（あちらは
    /// 渡された一覧の中でしか効かない）。
    ///
    /// 中央ペインが `entries` に無い選択を落とす [`FolderContentView.reload`]
    /// のと同じ形。**絞り込みが黙って緩む**ことにはなるが、残しても 0 件しか
    /// 返さない条件なので、緩むほうが利用者に説明できる。
    private func pruneSelectionToVisibleLabels() {
        var changed = false
        for (fieldID, selected) in selection {
            let visible = Set((labels[fieldID] ?? []).map(\.id))
            let kept = selected.intersection(visible)
            if kept.count != selected.count {
                changed = true
                if kept.isEmpty { selection.removeValue(forKey: fieldID) }
                else { selection[fieldID] = kept }
            }
        }
        if changed { bumpRevision() }
    }

    /// フィールドの並べ替え [LF-03][LG-07]。
    public func reorderFields(_ ordered: [FieldSummary],
                              services: LibraryServices) async {
        fields = ordered
        do {
            try await services.setFieldOrder(ordered.map(\.id))
        } catch {
            Log.ui.warning("フィールドの並び順を保存できない: \(String(describing: error))")
        }
    }
}
