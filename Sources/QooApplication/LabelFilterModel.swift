//
//  ラベルフィルタの状態 [LF-01〜LF-14][PN-01〜PN-06][RT-01〜RT-03]。
//
//  **選択はウインドウ固有状態** [ST-20][ST-21][LF-06]——DB に保存せず、ウインドウ
//  ごとに独立する。一方で**ピン留めとグループの並び順はライブラリ単位の永続設定**
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

    /// 並べる順に整えたグループ [LF-01][LF-03]。**ラベル 0 件は含まない**
    /// [LF-02][LG-05][LA-09]（`labelCount` はアーカイブ済みを数えない）。
    public private(set) var groups: [LabelGroupSummary] = []

    /// グループごとのラベル [LF-04]。アーカイブ済みは含まない [LF-12][LA-02]。
    public private(set) var labels: [LabelGroupID: [LabelSummary]] = [:]

    // MARK: - 選択（ウインドウ固有）

    /// グループ内 OR × グループ間 AND [LF-08〜LF-10]。初期状態は全 OFF [LF-06]。
    public private(set) var selection: [LabelGroupID: Set<LabelID>] = [:]

    /// 評価フィルタ [RT-01〜RT-03]。ラベルフィルタと AND [RT-02]。
    public var ratingFilter: FileQuery.RatingFilter? {
        didSet { if ratingFilter != oldValue { bumpRevision() } }
    }

    /// 展開しているグループ [LF-04]。
    public var expandedGroups: Set<LabelGroupID> = []

    /// 「もっと見る」で全ラベルを出しているグループ [PN-02][PN-05]。
    public var revealedGroups: Set<LabelGroupID> = []

    /// 「もっと見る」の中のインクリメンタル検索 [PN-05]。
    public var searchText: [LabelGroupID: String] = [:]

    // MARK: - 結果

    /// 条件に該当する件数 [LF-11]。**ライブラリ全体**に対する件数で、今いる
    /// フォルダの件数ではない——フィルタは「このライブラリの中で何件が条件に
    /// 合うか」を答えるもので、フォルダを移動するたびに数字が変わると
    /// 「絞り込みが効いているか」の手がかりにならない。
    public private(set) var matchedCount: Int?

    /// フィルタ全 OFF のときのライブラリ全体の件数。分母として出す [LF-11]。
    public private(set) var totalCount: Int?

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
        selection[label.groupID]?.contains(label.id) == true
    }

    /// 選んだラベルの総数。見出しのバッジに出す。
    public var selectedLabelCount: Int {
        selection.values.reduce(0) { $0 + $1.count }
    }

    /// そのグループで実際に並べるラベル [PN-02][PN-03][PN-06]。
    ///
    /// - 展開中（「もっと見る」）は全件。検索文字列があれば絞る [PN-05]
    /// - ピン留めがあればピン留めだけ [PN-02]
    /// - 無ければ名前順で上位 10 件 [PN-03]
    /// - **チェック中のラベルはピン対象外でも必ず含める** [PN-06]
    public func visibleLabels(in group: LabelGroupSummary) -> [LabelSummary] {
        let all = labels[group.id] ?? []
        if revealedGroups.contains(group.id) {
            let text = searchText[group.id] ?? ""
            guard !text.isEmpty else { return all }
            return all.filter { NameFilter.matches(name: $0.name, query: text) }
        }
        let pinned = all.filter(\.isPinned)
        let base = pinned.isEmpty
            ? Array(all.prefix(AppLimits.LabelFilter.collapsedLabelCount))
            : pinned
        let checked = all.filter { isSelected($0) }
        var seen = Set<LabelID>()
        // `labels` は既に「ピン留め優先・名前順」で来ているので、その順序を
        // 保ったまま重複を落とすだけでよい [PN-06]。
        return (base + checked).filter { seen.insert($0.id).inserted }
    }

    /// 「もっと見る」を出すべきか [PN-02][PN-03]。
    public func hasMoreLabels(in group: LabelGroupSummary) -> Bool {
        guard !revealedGroups.contains(group.id) else { return false }
        return (labels[group.id] ?? []).count > visibleLabels(in: group).count
    }

    // MARK: - 操作

    public func toggle(_ label: LabelSummary) {
        var set = selection[label.groupID] ?? []
        if set.contains(label.id) { set.remove(label.id) } else { set.insert(label.id) }
        if set.isEmpty { selection[label.groupID] = nil } else { selection[label.groupID] = set }
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

    /// ライブラリを切り替えたら選択をリセットする [ST-26]。
    private func resetSelection() {
        selection.removeAll()
        expandedGroups.removeAll()
        revealedGroups.removeAll()
        searchText.removeAll()
        if ratingFilter != nil { ratingFilter = nil }
        allowedChildNames = nil
        matchedCount = nil
        bumpRevision()
    }

    // MARK: - 読み込み

    /// 表示中のフォルダに対応するライブラリを解決し、グループとラベルを読む
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
            groups = []
            labels = [:]
            totalCount = nil
            loadFailure = nil
            return
        }
        do {
            let all = try await services.labelGroups(libraryID: library.id)
            // [LF-02][LG-05][LA-09] ラベルが 1 件も無いグループは出さない。
            let usable = all.filter { $0.labelCount > 0 }
            var loaded: [LabelGroupID: [LabelSummary]] = [:]
            for group in usable {
                loaded[group.id] = try await services.labels(groupID: group.id)
            }
            groups = usable
            labels = loaded
            totalCount = try await services.fileCount(FileQuery(libraryID: library.id))
            loadFailure = nil
        } catch {
            groups = []
            labels = [:]
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
    public func setPinned(_ label: LabelSummary, _ pinned: Bool,
                          services: LibraryServices) async {
        do {
            try await services.setLabelPinned(label.id, pinned)
            labels[label.groupID] = try await services.labels(groupID: label.groupID)
        } catch {
            Log.ui.warning("ピン留めを保存できない: \(String(describing: error))")
        }
    }

    /// グループの並べ替え [LF-03][LG-07]。
    public func reorderGroups(_ ordered: [LabelGroupSummary],
                              services: LibraryServices) async {
        groups = ordered
        do {
            try await services.setLabelGroupOrder(ordered.map(\.id))
        } catch {
            Log.ui.warning("グループの並び順を保存できない: \(String(describing: error))")
        }
    }
}
