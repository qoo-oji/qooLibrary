//
//  シリーズの提案タブ [SS-01〜SS-08][19章 §19.5][15章 §15.15]（ステージ 10）。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（無視の出し分け・検索・
//  既定で選ぶライブラリ・適用の下ごしらえ）を自動テストで固定できなくなる
//  （`FileVaultModel` と同じ理由）。
//
//  ## 左ペインの件数は選択中のライブラリだけ［実測にもとづく判断］
//  他の 2 タブは 1 本の SQL（`GROUP BY`）で全ライブラリの件数を出せるが、
//  提案は**保存された行が無い**（無視印だけがスキーマにある）ので、数えるには
//  検出を走らせるしかない。プリセットはどれもファイル名フォーマットで
//  `@series` を取らないため候補は事実上ライブラリ全件になり、**実コーパスを
//  5 万件へ増やした実測で 403 ms** かかった。左ペインは ⌘Z と走査のたびに
//  読み直すので、全ライブラリぶんを毎回走らせると窓が重くなる。
//
//  ## 検出はこのタブを見ているときだけ走らせる
//  同じ理由。`MaintenanceWindow` が可視のタブだけを読み直す。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class SeriesSuggestionModel {

    /// 一覧の 1 行＝提案 1 件。
    public struct Group: Sendable, Hashable, Identifiable {
        public let suggestion: SeriesSuggestion
        /// 「以後出さない」が全員に立っているか [SS-05]。
        public let isIgnored: Bool
        public var id: FileID { suggestion.id }

        public init(suggestion: SeriesSuggestion, isIgnored: Bool) {
            self.suggestion = suggestion
            self.isIgnored = isIgnored
        }
    }

    public enum State: Sendable, Equatable {
        case notReady
        case loading
        case noLibrary
        case ready
        case failed(String)
    }

    public private(set) var state: State = .notReady
    public private(set) var libraries: [LibrarySummary] = []
    /// **選択中のライブラリのぶんしか入らない**（上記）。他のライブラリは
    /// キーごと現れず、左ペインは件数を出さない。
    public private(set) var suggestionCounts: [LibraryID: Int] = [:]
    public private(set) var groups: [Group] = []

    public var selectedLibraryID: LibraryID? {
        didSet { guard oldValue != selectedLibraryID else { return }; selection = [] }
    }
    /// 一括で適用・無視するための選択。
    public var selection: Set<FileID> = []
    /// 「無視したものも表示」[UR2-04 と同じ考え方]。
    public var showsIgnored: Bool = false {
        didSet { guard oldValue != showsIgnored else { return }; pruneSelection() }
    }
    public var searchText: String = ""

    private let commands: CommandStack
    private var services: LibraryServices?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 表示（純粋関数）

    public var visibleGroups: [Group] {
        Self.visible(groups, showsIgnored: showsIgnored, matching: searchText)
    }

    /// **判定はここ 1 箇所。** View に書くとテストで固定できず、`reload` に
    /// 埋めると検索のたびに検出を走らせ直すことになる。
    ///
    /// 検索は `NameFilter` なので**全角で打っても半角の綴りに当たる**
    /// [LE-12 と同じ判定]。シリーズ名・フォルダ・メンバーのタイトルを見る
    /// ——「どの本の話か」で探すのは自然な引き方。
    nonisolated public static func visible(_ groups: [Group], showsIgnored: Bool,
                                           matching searchText: String) -> [Group] {
        groups.filter { group in
            guard showsIgnored || !group.isIgnored else { return false }
            guard !searchText.isEmpty else { return true }
            if NameFilter.matches(name: group.suggestion.seriesName, query: searchText) {
                return true
            }
            if NameFilter.matches(name: group.suggestion.folderPath, query: searchText) {
                return true
            }
            return group.suggestion.members.contains {
                NameFilter.matches(name: $0.title, query: searchText)
            }
        }
    }

    /// 既定で選ぶライブラリ。**指定されたものが最優先**——その登録の提案を
    /// 見に来たのだから、空でもそのライブラリを見せる（「無かった」も答え）。
    ///
    /// **件数で選び直さない**（`FileVaultModel` との違い）——件数を知るには
    /// 検出を走らせるしかなく、「中身のある最初のライブラリ」を選ぶために
    /// 全ライブラリぶん走らせては本末転倒である。
    nonisolated public static func defaultLibrary(from libraries: [LibrarySummary],
                                                  preferring preferred: LibraryID?) -> LibraryID? {
        if let preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        return libraries.first?.id
    }

    public var selectedLibrary: LibrarySummary? {
        libraries.first { $0.id == selectedLibraryID }
    }

    /// 適用・無視ができるか。
    ///
    /// **オフラインでも触れる** [SB-05 とは逆]。適用も無視も DB だけを書く
    /// ——保管庫の「戻す」が実ファイルを動かすのとは性質が違う（未整理タブと
    /// 同じ判断）。
    public var canModify: Bool { selectedLibraryID != nil }

    public var selectedGroups: [Group] {
        visibleGroups.filter { selection.contains($0.id) }
    }

    /// 提案が 1 件も無いか。**検索で 0 件になった場合と区別する**ため、
    /// `visibleGroups` ではなく読み込んだ生データを見る——「提案はありません」と
    /// 「一致しません」は次の一手が違う（未整理タブで実機で踏んだ形）。
    public var hasNoSuggestions: Bool { groups.isEmpty }

    /// 無視だけを隠している状態か。空状態の文言を分けるのに使う。
    public var hiddenIgnoredCount: Int {
        showsIgnored ? 0 : groups.filter(\.isIgnored).count
    }

    // MARK: - 読み込み

    public func prepare(services: LibraryServices, preferring libraryID: LibraryID? = nil) async {
        self.services = services
        guard services.isReady else { state = .notReady; return }
        state = .loading
        await reload(preferring: libraryID)
    }

    /// - Parameter preferred: 入口が指定したライブラリ。**指定があるときだけ
    ///   選択を動かす**——⌘Z のたびに呼ばれる `reload()` が、利用者の選んだ
    ///   ライブラリを勝手に切り替えてはならない。
    public func reload(preferring preferred: LibraryID? = nil) async {
        guard let services, services.isReady else { state = .notReady; return }
        libraries = services.libraries
        guard !libraries.isEmpty else {
            groups = []; suggestionCounts = [:]
            selectedLibraryID = nil
            state = .noLibrary
            return
        }
        let current = selectedLibraryID
        if preferred != nil || current == nil
            || !libraries.contains(where: { $0.id == current }) {
            selectedLibraryID = Self.defaultLibrary(from: libraries, preferring: preferred)
        }
        guard let libraryID = selectedLibraryID else {
            groups = []; suggestionCounts = [:]; state = .noLibrary; return
        }
        // **読み直しでは状態を触らない。** `.loading` へ落とすと、提案が
        // 0 件のライブラリで ⌘Z のたびに空状態がスピナーへ入れ替わる
        // ——`prepare()`（初回）だけがスピナーを出す。
        do {
            let report = try await services.seriesSuggestions(libraryID: libraryID)
            groups = report.suggestions.map {
                Group(suggestion: $0, isIgnored: report.isIgnored($0))
            }
            // **数えるのは選択中のライブラリだけ**（型の注記を参照）。
            suggestionCounts = [libraryID: groups.filter { !$0.isIgnored }.count]
            pruneSelection()
            state = .ready
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    private func pruneSelection() {
        let visible = Set(visibleGroups.map(\.id))
        selection = selection.filter { visible.contains($0) }
    }

    // MARK: - 操作（すべて CommandStack を通す）

    /// 提案を適用する [SS-06]。
    ///
    /// **複数のグループをまとめて適用したときは 1 つの Undo 単位** [UD-04]。
    /// グループごとにコマンドを積むと、世代番号が N 回動いて
    /// **その回数だけ検出が走り直す**（5 万件で 1 回 400 ms）——しかも適用の
    /// ループがまだ回っている最中に重なる［code-review の指摘］。
    public func apply(_ groups: [Group]) async throws {
        guard let services, !groups.isEmpty else { return }
        var batch: [any Command] = []
        for group in groups where !group.isIgnored {
            let ids = group.suggestion.members.map(\.id)
            let scopes = try await services.protectedScopes(ids: ids)
            var previous: [ApplySeriesSuggestionCommand.Previous] = []
            for id in ids {
                // **書く直前に行を引き直す。** 読み込み時の写しを使うと、その
                // 間の編集（⌘Z を含む）で変わった値を「変更前」として控えて
                // しまい、取り消しがいま持っていない値へ戻す
                //（`RatingEditorModel` で実際に踏んだ形）。
                guard let row = try await services.fileRow(id: id) else { continue }
                previous.append(.init(fileID: id, fields: FileFieldEdit(row),
                                      scopes: scopes[id] ?? []))
            }
            guard !previous.isEmpty else { continue }
            batch.append(ApplySeriesSuggestionCommand(
                suggestion: group.suggestion, previous: previous, services: services))
        }
        try await run(batch, displayName: applyName(batch.count))
        await reload()
    }

    /// 束ねたときの Undo メニューの文言 [UD-06]。1 件なら子の文言をそのまま使う。
    ///
    /// **実際に積んだ数で書く**——行が引けずに飛ばしたグループがあると、
    /// 選択した数と食い違う。
    private func applyName(_ count: Int) -> String { "\(count) 件のシリーズ設定" }

    /// 1 件ならそのまま、複数なら 1 つの Undo 単位へ束ねる [UD-04]。
    private func run(_ batch: [any Command], displayName: String) async throws {
        guard let first = batch.first else { return }
        if batch.count == 1 {
            _ = try await commands.run(first)
        } else {
            _ = try await commands.run(
                CompositeCommand(displayName: displayName, children: batch))
        }
    }

    public func applySelected() async throws {
        try await apply(selectedGroups)
    }

    /// 「以後この提案を出さない」の付け外し [SS-05]。
    public func setIgnored(_ groups: [Group], _ ignored: Bool) async throws {
        guard let services, !groups.isEmpty else { return }
        var batch: [any Command] = []
        for group in groups {
            let members = group.suggestion.members
            let ids = members.map(\.id)
            let before = try await services.seriesSuggestionIgnoredTitles(ids: ids)
            let previous = ids.map {
                SetSeriesSuggestionIgnoredCommand.Previous(fileID: $0, ignoredTitle: before[$0])
            }
            // 立てる値は**そのファイルの現在のタイトル** [SS-05]。
            let marks = ignored
                ? Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.title) })
                : [:]
            batch.append(SetSeriesSuggestionIgnoredCommand(
                previous: previous, marks: marks,
                seriesName: group.suggestion.seriesName, services: services))
        }
        let verb = ignored ? "以後出さない設定" : "無視の解除"
        try await run(batch, displayName: "\(groups.count) 件の提案の\(verb)")
        await reload()
    }

    public func ignoreSelected() async throws {
        try await setIgnored(selectedGroups.filter { !$0.isIgnored }, true)
    }
}
