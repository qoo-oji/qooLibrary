//
//  重複の比較・整理 [DU-20〜DU-29]。
//
//  **この画面だけが実ファイルを消す。** 他の重複まわりの機能（畳んで見せる・
//  代表を選ぶ）は表示を変えるだけだが、ここは取り返しの付かない操作を伴う
//  ので、①何が失われるかを実行前に必ず出す [DU-27] ②既定はゴミ箱 [DU-24]
//  ③1 つの Undo 単位 [DU-28] の 3 つを崩さないこと。
//
import Foundation
import QooInfrastructure
import QooKit

/// 比較ビューの 1 行 [DU-20][DU-21]。
public struct DuplicateComparisonRow: Sendable, Identifiable {
    /// ページ数・解像度は容器を開かないと分からないので遅延取得する
    /// [DU-22][MD-01]。**「まだ数えていない」と「数えたが取れなかった」を
    /// 区別する**——前者はプレースホルダ、後者は「—」で、後者を 0 と
    /// 見なすと一括選択規則 [DU-25] が中身のあるほうを捨てる。
    public enum Measurement: Sendable, Equatable {
        case pending
        case measured(pageCount: Int, width: Int?, height: Int?)
        case unavailable
    }

    public internal(set) var file: FileRow
    public let url: URL
    /// 付与ラベルの名前 [DU-21]。表示のみ。
    public let labelNames: [String]
    public var measurement: Measurement

    public var id: FileID { file.id }

    /// 所在フォルダ [DU-21]。ライブラリの根から見た親。根直下なら空。
    public var folder: String {
        let parent = (file.relativePath as NSString).deletingLastPathComponent
        return parent
    }

    public init(file: FileRow, url: URL, labelNames: [String],
                measurement: Measurement = .pending) {
        self.file = file
        self.url = url
        self.labelNames = labelNames
        self.measurement = measurement
    }
}

/// 削除で失われるもの [DU-27]。
public struct DuplicateLossReport: Sendable, Equatable {
    /// 残す側に無いラベル。**引き継ぐ**を選べば付け直す。
    public let labelsOnlyOnDoomed: [LabelID: String]
    /// 捨てる側にあった最高評価。残す側が未評価のときだけ意味を持つ。
    public let bestDoomedRating: Int
    public let keeperRating: Int

    public var hasAnythingToInherit: Bool {
        !labelsOnlyOnDoomed.isEmpty || (keeperRating == 0 && bestDoomedRating > 0)
    }

    public init(labelsOnlyOnDoomed: [LabelID: String], bestDoomedRating: Int,
                keeperRating: Int) {
        self.labelsOnlyOnDoomed = labelsOnlyOnDoomed
        self.bestDoomedRating = bestDoomedRating
        self.keeperRating = keeperRating
    }

    /// 何が失われるかを数える [DU-27]。**純粋関数**——画面を組み立てずに
    /// 固定できるようにしてある（この判断が誤ると、引き継いだつもりの
    /// ラベルが消えたまま実ファイルだけ無くなる）。
    ///
    /// **突き合わせは `LabelID`。** 名前で比べると、同名の別グループのラベルを
    /// 取り違える [LB-01 はグループ内での一意しか保証しない]。
    ///
    /// **残す側で保護されたフィールドへは引き継がない** [PR-02]。保護は
    /// 「このフィールドの状態は利用者が決めた」という意味なので、捨てる側に
    /// 付いているからといって足すのは約束違反になる。
    public static func make(keepID: FileID?, rows: [DuplicateComparisonRow],
                            assignments: [FileID: Set<LabelID>],
                            names: [LabelID: String],
                            groupByLabel: [LabelID: LabelGroupID] = [:],
                            keeperProtections: Set<ProtectionScope> = [])
        -> DuplicateLossReport
    {
        guard let keepID, let keeper = rows.first(where: { $0.id == keepID }) else {
            return DuplicateLossReport(labelsOnlyOnDoomed: [:], bestDoomedRating: 0,
                                       keeperRating: 0)
        }
        let doomed = rows.filter { $0.id != keepID }
        let keeperLabels = assignments[keepID] ?? []
        let protectedFields = keeperProtections.protectedFields
        var lost: [LabelID: String] = [:]
        for row in doomed {
            for labelID in assignments[row.id] ?? [] where !keeperLabels.contains(labelID) {
                if let group = groupByLabel[labelID], protectedFields.contains(group) { continue }
                lost[labelID] = names[labelID] ?? ""
            }
        }
        return DuplicateLossReport(
            labelsOnlyOnDoomed: lost,
            bestDoomedRating: doomed.map(\.file.rating).max() ?? 0,
            keeperRating: keeper.file.rating)
    }
}

@MainActor
@Observable
public final class DuplicateResolutionModel {
    public enum State: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var state: State = .loading
    public private(set) var rows: [DuplicateComparisonRow] = []
    /// 残す 1 件 [DU-24]。**規則を当てても書き換わるだけ**で、利用者は行ごとに
    /// 選び直せる [DU-26]。
    public var keepID: FileID?
    /// 直近に当てた規則。画面に「いま何で選ばれているか」を出すために持つ。
    public private(set) var appliedRule: KeepRule?

    private var library: LibrarySummary?
    private var mode: DuplicateGrouping = .off
    private var generation = 0
    /// ラベルの紐づけ。**失われるものの判定は名前ではなく `LabelID` で行う**
    /// ——名前で突き合わせると、同名の別グループのラベルを取り違える。
    private var assignments: [FileID: Set<LabelID>] = [:]
    private var labelNamesByID: [LabelID: String] = [:]
    /// ラベル → そのフィールド。保護の判定と、引き継ぎコマンドの組み立てに要る。
    private var groupByLabel: [LabelID: LabelGroupID] = [:]
    /// 残す側の保護スコープ [PR-02]。
    private var protections: [FileID: Set<ProtectionScope>] = [:]

    public init() {}

    /// 捨てられる側 [DU-24]。
    public var doomed: [DuplicateComparisonRow] {
        guard let keepID else { return [] }
        return rows.filter { $0.id != keepID }
    }

    public var canDelete: Bool { keepID != nil && rows.count > 1 }

    // MARK: - 読み込み

    public func load(around id: FileID, library: LibrarySummary,
                     services: LibraryServices) async {
        self.library = library
        self.mode = library.duplicateGrouping
        generation &+= 1
        let mine = generation
        state = .loading
        do {
            let members = try await services.duplicateGroupMembers(containing: id, mode: mode)
            let assignments = try await services.labelAssignments(fileIDs: members.map(\.id))
            let protections = try await services.protectedScopes(ids: members.map(\.id))
            let (names, groups) = try await Self.labelNames(library: library, services: services)
            guard mine == generation else { return }
            self.assignments = assignments
            self.protections = protections
            self.labelNamesByID = names
            self.groupByLabel = groups
            let root = URL(fileURLWithPath: library.resolvedPath, isDirectory: true)
            rows = members.map { file in
                DuplicateComparisonRow(
                    file: file,
                    url: root.appendingPathComponent(file.relativePath,
                                                     isDirectory: file.isBookFolder),
                    labelNames: Self.sortedNames(of: assignments[file.id] ?? [], names: names),
                    // 既に数えてある行はそのまま使う [MD-02]——開き直さない。
                    measurement: file.pageCount.map {
                        .measured(pageCount: $0, width: file.firstImageWidth,
                                  height: file.firstImageHeight)
                    } ?? .pending)
            }
            // 既定は代表——**いちばん残しそうなもの**を最初から選んでおく。
            keepID = rows.first?.id
            state = .ready
        } catch {
            guard mine == generation else { return }
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// 表示用に名前を並べる。**式を分けてあるのは型検査のため**——`map` の
    /// 中へ直に書くとコンパイラが「型検査に時間がかかりすぎる」で落ちる。
    private static func sortedNames(of ids: Set<LabelID>,
                                    names: [LabelID: String]) -> [String] {
        ids.compactMap { names[$0] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func labelNames(library: LibrarySummary,
                                   services: LibraryServices) async throws
        -> (names: [LabelID: String], groups: [LabelID: LabelGroupID])
    {
        var out: [LabelID: String] = [:]
        var groups: [LabelID: LabelGroupID] = [:]
        for group in try await services.labelGroups(libraryID: library.id) {
            for label in try await services.labels(groupID: group.id, includeArchived: true) {
                out[label.id] = label.name
                groups[label.id] = group.id
            }
        }
        return (out, groups)
    }

    /// 数えていない行だけを順に数える [DU-22][MD-03]。
    ///
    /// **同時実行の制限は `ArchiveMetadataService` が持つ**ので、ここでは
    /// 素直に順に投げてよい。取り消されたら途中で止まる。
    public func measurePending(services: LibraryServices) async {
        let mine = generation
        for row in rows where row.measurement == .pending {
            if Task.isCancelled || mine != generation { return }
            let measured = try? await services.measureArchiveMetadata(for: row.url, id: row.id)
            guard mine == generation else { return }
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { continue }
            rows[index] = Self.applying(measured, to: rows[index])
        }
    }

    /// 測った結果を行へ写す。**純粋関数**——`measurement` と `file` の
    /// 両方を必ず一緒に更新するために切り出してある。
    ///
    /// **片方だけ更新すると静かに壊れる**: 画面は `measurement` を出すが、
    /// 残す 1 件を選ぶ規則 [DU-25] は `FileRow` を見るので、`file` を
    /// 飛ばすと**「ページ数が最多」を選んでもページ数を見ていない**という、
    /// 画面からは絶対に気づけない形になる——しかもその判断が
    /// **取り消せない削除**を駆動する［`code-review` が検出］。
    static func applying(_ metadata: ArchiveMetadata?,
                         to row: DuplicateComparisonRow) -> DuplicateComparisonRow {
        guard let metadata else {
            var out = row
            out.measurement = .unavailable
            return out
        }
        let w = metadata.firstImageSize.map { Int($0.width) }
        let h = metadata.firstImageSize.map { Int($0.height) }
        var out = row
        out.measurement = .measured(pageCount: metadata.imageCount, width: w, height: h)
        out.file = row.file.withArchiveMetadata(pageCount: metadata.imageCount,
                                                width: w, height: h)
        return out
    }

    // MARK: - 一括選択規則 [DU-25][DU-26]

    /// 規則を当てて「残す 1 件」を選び直す。**実行はしない**——結果は
    /// 画面に出るだけで、行ごとに選び直せる [DU-26]。
    public func apply(_ rule: KeepRule) {
        // 数え終わっていない値を使う規則は、数え終わってから当てるほうが
        // 正しい結果になる。**それでも当てる**——`DuplicateSelection` が
        // 未取得を最下位に置くので、少なくとも「取れているものの中で最良」
        // にはなる [DU-22 の趣旨]。
        guard let picked = DuplicateSelection.keep(rule, from: rows.map(\.file)) else { return }
        keepID = picked.id
        appliedRule = rule
    }

    /// 手で選び直す [DU-26]。規則の表示は消す——もう規則どおりではない。
    public func chooseKeeper(_ id: FileID) {
        keepID = id
        appliedRule = nil
    }

    /// テスト用の差し込み口。**製品の経路からは呼ばない**——`load` が
    /// 組み立てるのと同じ形の状態を、DB を用意せずに作るためだけにある。
    func seedForTesting(rows: [DuplicateComparisonRow], keepID: FileID?,
                        assignments: [FileID: Set<LabelID>] = [:],
                        names: [LabelID: String] = [:],
                        groupByLabel: [LabelID: LabelGroupID] = [:],
                        protections: [FileID: Set<ProtectionScope>] = [:]) {
        self.rows = rows
        self.keepID = keepID
        self.assignments = assignments
        self.labelNamesByID = names
        self.groupByLabel = groupByLabel
        self.protections = protections
        self.state = .ready
    }

    // MARK: - 失われるもの [DU-27]

    /// 残す側の保護スコープ [PR-02]。
    private var keeperProtections: Set<ProtectionScope> {
        guard let keepID else { return [] }
        return protections[keepID] ?? []
    }

    /// 削除で失われるラベル・評価 [DU-27]。
    public func lossReport() -> DuplicateLossReport {
        DuplicateLossReport.make(keepID: keepID, rows: rows, assignments: assignments,
                                 names: labelNamesByID, groupByLabel: groupByLabel,
                                 keeperProtections: keeperProtections)
    }
}

// MARK: - 削除の組み立て [DU-24][DU-27][DU-28]

extension DuplicateResolutionModel {

    /// 削除の下ごしらえ [DU-24][NV4-01]。
    ///
    /// **ゴミ箱を使えるかは実行前に調べる。** 使えない場所（ネットワーク共有、
    /// まだ何も捨てていない外付け）では完全削除へ振り替わり、**⌘Z が効かなく
    /// なる** [PD-05]——確認の文言がそれを言わないと、いちばん取り返しの
    /// つかない場面で嘘をつくことになる（`FileVaultModel` で同じ形を直している）。
    public func planDelete() async -> DuplicateDeletePlan? {
        guard canDelete, let keepID,
              let keeper = rows.first(where: { $0.id == keepID }) else { return nil }
        let targets = doomed
        guard !targets.isEmpty else { return nil }
        let urls = targets.map(\.url)
        let usesTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: urls) }
        return DuplicateDeletePlan(keeper: keeper, doomed: targets, usesTrash: usesTrash,
                                   loss: lossReport(), groupByLabel: groupByLabel,
                                   keeperProtections: keeperProtections)
    }

    /// 1 つの Undo 単位にまとめる [DU-28]。
    ///
    /// **引き継ぎは削除より先**——`fileLabel` は `managedFile` の削除で cascade
    /// されるので、後からでは何を引き継ぐべきか分からなくなる。
    ///
    /// `inheritMetadata` が偽なら引き継ぎの子を入れない [DU-27]。
    public static func makeDeleteCommand(plan: DuplicateDeletePlan, inheritMetadata: Bool,
                                         services: LibraryServices) -> CompositeCommand {
        var children: [any Command] = []
        let keeperName = DuplicateResolutionModel.subjectName(plan.keeper)

        if inheritMetadata {
            // ラベルを 1 つずつ。**新しいコマンドは書かない**——`AssignLabelCommand`
            // が「変更前の状態を 1 件ずつ持って書き戻す」を既に満たしている
            // （2-13 で「新しいコマンドを 1 つも書かなかった」のと同じ判断）。
            for (labelID, name) in plan.loss.labelsOnlyOnDoomed
                .sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard let group = plan.groupByLabel[labelID] else { continue }
                children.append(AssignLabelCommand(
                    labelID: labelID, groupID: group, labelName: name,
                    previous: [.init(fileID: plan.keeper.id, url: plan.keeper.url,
                                     wasAssigned: false,
                                     protectedScopes: plan.keeperProtections)],
                    assigning: true, subjectName: keeperName, services: services))
            }
            // 評価は**残す側が未評価のときだけ**引き継ぐ [DU-27 の趣旨]。
            // 付いている評価を上書きすると、利用者が付けた値が黙って消える。
            if plan.loss.keeperRating == 0, plan.loss.bestDoomedRating > 0 {
                children.append(SetRatingCommand(
                    // **変更前の星は実際の値を渡す。** 上の条件があるので今は
                    // 必ず 0 だが、0 を決め打ちすると条件を緩めた瞬間に
                    // 「⌘Z が評価を 0 にする」という戻し間違いになる。
                    targets: [.init(id: plan.keeper.id, url: plan.keeper.url,
                                    previousStars: plan.loss.keeperRating)],
                    stars: plan.loss.bestDoomedRating,
                    subjectName: keeperName, services: services))
            }
        }

        let urls = plan.doomed.map(\.url)
        children.append(plan.usesTrash
            ? TrashCommand(items: urls)
            : DeletePermanentlyCommand(items: urls))
        children.append(DeleteOrphanedFilesCommand(
            fileIDs: plan.doomed.map(\.id),
            names: plan.doomed.map { $0.file.filename },
            services: services))

        return CompositeCommand(
            displayName: "「\(keeperName)」を残して \(plan.doomed.count) 件を削除",
            children: children)
    }

    public static func subjectName(_ row: DuplicateComparisonRow) -> String {
        row.file.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? row.file.filename
    }
}

/// 削除の下ごしらえの結果 [DU-24][DU-27]。
public struct DuplicateDeletePlan: Sendable, Identifiable {
    /// 確認シートを `.sheet(item:)` で出すため。組は残す 1 件で一意。
    public var id: FileID { keeper.id }

    public let keeper: DuplicateComparisonRow
    public let doomed: [DuplicateComparisonRow]
    /// ゴミ箱を経由できるか。`false` なら完全削除になり **⌘Z は効かない** [PD-05]。
    public let usesTrash: Bool
    public let loss: DuplicateLossReport
    /// ラベル → そのフィールド。引き継ぎで保護を立てるのに要る [PR-03]。
    public let groupByLabel: [LabelID: LabelGroupID]
    /// 残す側の変更前の保護スコープ。⌘Z がここへちょうど戻す。
    public let keeperProtections: Set<ProtectionScope>

    public init(keeper: DuplicateComparisonRow, doomed: [DuplicateComparisonRow],
                usesTrash: Bool, loss: DuplicateLossReport,
                groupByLabel: [LabelID: LabelGroupID] = [:],
                keeperProtections: Set<ProtectionScope> = []) {
        self.keeper = keeper
        self.doomed = doomed
        self.usesTrash = usesTrash
        self.loss = loss
        self.groupByLabel = groupByLabel
        self.keeperProtections = keeperProtections
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
