//
//  重複の比較・削除の判定 [DU-24〜DU-28]。
//
//  **この画面だけが実ファイルを消す**ので、判断（何を残すか・何が失われるか・
//  取り消せるか）はすべて純粋関数へ切り出して直に固定する。
//
import CoreGraphics
import Foundation
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

@Suite("重複の比較・削除 [DU-24〜DU-28]")
struct DuplicateResolutionTests {

    private static func row(_ id: Int64, name: String, title: String? = "作品名A",
                            rating: Int = 0, size: Int64 = 100,
                            pages: Int? = nil, labels: [String] = [])
        -> DuplicateComparisonRow
    {
        let file = FileRow(
            id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
            relativePath: "作者A/\(name)", filename: name, fileSize: size,
            createdAt: .distantPast, modifiedAt: .distantPast,
            title: title, seriesName: nil, volume: .none, rating: rating,
            state: .active, isArchived: false, isBookFolder: false,
            pageCount: pages)
        return DuplicateComparisonRow(
            file: file, url: URL(fileURLWithPath: "/tmp/lib/作者A/\(name)"),
            labelNames: labels,
            measurement: pages.map { .measured(pageCount: $0, width: nil, height: nil) }
                ?? .pending)
    }

    private static func label(_ n: Int64) -> LabelID { LabelID(rawValue: n) }

    // MARK: - 失われるもの [DU-27]

    @Test("残す側に無いラベルだけが「失われる」に挙がる [DU-27]")
    func onlyLabelsMissingFromTheKeeperAreReported() {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = Self.row(2, name: "捨てる.cbz")
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, doomed],
            assignments: [keeper.id: [Self.label(10): .auto],
                          doomed.id: [Self.label(10): .auto, Self.label(20): .manual]],
            names: [Self.label(10): "共通", Self.label(20): "捨てる側だけ"])
        #expect(report.labelsOnlyOnDoomed == [Self.label(20): "捨てる側だけ"])
    }

    /// **`manuallyRemoved` を引き継いではならない** [RC-04]。
    ///
    /// あれは「利用者が外すと決めた」印なので、引き継ぐと**外したはずの
    /// ラベルが復活する**。しかも復活したことは画面から読み取れない。
    @Test("手で外した印のラベルは引き継がない [DU-27][RC-04]")
    func manuallyRemovedLabelsAreNotInherited() {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = Self.row(2, name: "捨てる.cbz")
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, doomed],
            assignments: [doomed.id: [Self.label(30): .manuallyRemoved]],
            names: [Self.label(30): "外したもの"])
        #expect(report.labelsOnlyOnDoomed.isEmpty)
        #expect(!report.hasAnythingToInherit)
    }

    @Test("捨てる側の最高評価を拾う [DU-27]")
    func bestDoomedRatingIsReported() {
        let keeper = Self.row(1, name: "残す.cbz", rating: 0)
        let report = DuplicateLossReport.make(
            keepID: keeper.id,
            rows: [keeper, Self.row(2, name: "a.cbz", rating: 3),
                   Self.row(3, name: "b.cbz", rating: 5)],
            assignments: [:], names: [:])
        #expect(report.bestDoomedRating == 5)
        #expect(report.keeperRating == 0)
        #expect(report.hasAnythingToInherit)
    }

    /// 残す側に評価が付いていれば、引き継ぐものは無い——**上書きしない**。
    @Test("残す側が評価済みなら評価は引き継がない [DU-27]")
    func anExistingRatingIsNeverOverwritten() {
        let keeper = Self.row(1, name: "残す.cbz", rating: 1)
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, Self.row(2, name: "a.cbz", rating: 5)],
            assignments: [:], names: [:])
        #expect(!report.hasAnythingToInherit, "★1 を ★5 で黙って上書きしない")
    }

    // MARK: - 一括選択規則 [DU-25]

    @Test("規則を当てると残す 1 件が変わる [DU-25][DU-26]")
    func applyingARuleChangesTheKeeper() async {
        let model = await DuplicateResolutionModel()
        await MainActor.run {
            model.seedForTesting(rows: [Self.row(1, name: "小さい.cbz", size: 10),
                                        Self.row(2, name: "大きい.cbz", size: 900)],
                                 keepID: FileID(rawValue: 1))
            model.apply(.largestSize)
            #expect(model.keepID == FileID(rawValue: 2))
            #expect(model.appliedRule == .largestSize)
            // 手で選び直すと規則の表示は消える——もう規則どおりではない。
            model.chooseKeeper(FileID(rawValue: 1))
            #expect(model.keepID == FileID(rawValue: 1))
            #expect(model.appliedRule == nil)
        }
    }

    // MARK: - 測った値が規則へ届くこと [DU-22][DU-25]

    /// **測った結果は `measurement` と `file` の両方へ写す。**
    ///
    /// 画面は `measurement` を出すが、残す 1 件を選ぶ規則 [DU-25] は
    /// `FileRow` を見る。片方だけ更新すると「ページ数が最多」を選んでも
    /// ページ数を見ておらず、**画面からは気づけないまま取り消せない削除を
    /// 駆動する**［`code-review` が検出した欠陥の回帰検査］。
    @Test("測ったページ数が「ページ数が最多」に効く [DU-22][DU-25]")
    func measuredPageCountsReachTheKeepRule() async {
        await MainActor.run {
            let thin = DuplicateResolutionModel.applying(
                ArchiveMetadata(entryCount: 12, imageCount: 12, subfolderCount: 0,
                                firstImageSize: CGSize(width: 800, height: 1200)),
                to: Self.row(1, name: "薄い.cbz", size: 900))
            let thick = DuplicateResolutionModel.applying(
                ArchiveMetadata(entryCount: 220, imageCount: 220, subfolderCount: 0,
                                firstImageSize: CGSize(width: 1600, height: 2400)),
                to: Self.row(2, name: "厚い.cbz", size: 10))

            #expect(thin.file.pageCount == 12, "`file` にも写っていること")
            #expect(thick.file.firstImageWidth == 1600)

            let model = DuplicateResolutionModel()
            model.seedForTesting(rows: [thin, thick], keepID: thin.id)
            model.apply(.mostPages)
            #expect(model.keepID == thick.id, "ページ数の多いほうが残る")
            model.apply(.highestResolution)
            #expect(model.keepID == thick.id, "解像度の高いほうが残る")
        }
    }

    @Test("読めなかった行は「取れなかった」になり、値は入らない [MD-01]")
    func unreadableRowsStayUnmeasured() async {
        await MainActor.run {
            let row = DuplicateResolutionModel.applying(nil, to: Self.row(1, name: "壊れた.cbz"))
            #expect(row.measurement == .unavailable)
            #expect(row.file.pageCount == nil, "0 を書き込まない——中身が空の本に見える")
        }
    }

    /// **残す側で「外すと決めた」ラベルを引き継がない** [RC-04]。
    ///
    /// `manuallyRemoved` は「このファイルにはこのラベルを付けない」という
    /// 利用者の判断。捨てる側に付いているからといって引き継ぐと、
    /// **外したはずのラベルが復活する**［`code-review` が検出］。
    @Test("残す側で外したラベルは引き継がない [DU-27][RC-04]")
    func labelsTheKeeperRemovedAreNotReattached() {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = Self.row(2, name: "捨てる.cbz")
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, doomed],
            assignments: [keeper.id: [Self.label(40): .manuallyRemoved],
                          doomed.id: [Self.label(40): .manual]],
            names: [Self.label(40): "残す側で外したもの"])
        #expect(report.labelsOnlyOnDoomed.isEmpty)
    }

    // MARK: - 削除の 1 単位 [DU-24][DU-28]

    private static func plan(keeper: DuplicateComparisonRow,
                             doomed: [DuplicateComparisonRow],
                             usesTrash: Bool = true,
                             loss: DuplicateLossReport = .init(labelsOnlyOnDoomed: [:],
                                                               bestDoomedRating: 0,
                                                               keeperRating: 0))
        -> DuplicateDeletePlan
    {
        DuplicateDeletePlan(keeper: keeper, doomed: doomed, usesTrash: usesTrash, loss: loss)
    }

    /// **引き継ぎは削除より先。** `fileLabel` は `managedFile` の削除で
    /// cascade されるので、後からでは何を引き継ぐべきか分からなくなる。
    @Test("引き継ぎは削除より前に置かれる [DU-27][DU-28]")
    func inheritanceRunsBeforeDeletion() async {
        let kinds = await MainActor.run { () -> [String] in
            let keeper = Self.row(1, name: "残す.cbz")
            let loss = DuplicateLossReport(labelsOnlyOnDoomed: [Self.label(20): "引き継ぐ"],
                                           bestDoomedRating: 4, keeperRating: 0)
            let command = DuplicateResolutionModel.makeDeleteCommand(
                plan: Self.plan(keeper: keeper, doomed: [Self.row(2, name: "捨てる.cbz")],
                                loss: loss),
                inheritMetadata: true, services: LibraryServices.shared)
            return command.children.map { String(describing: type(of: $0)) }
        }
        let assignIndex = kinds.firstIndex { $0.contains("AssignLabel") }
        let ratingIndex = kinds.firstIndex { $0.contains("SetRating") }
        let trashIndex = kinds.firstIndex { $0.contains("Trash") }
        #expect(assignIndex != nil && trashIndex != nil)
        #expect(assignIndex! < trashIndex!)
        #expect(ratingIndex! < trashIndex!)
    }

    @Test("引き継がないと選べば、引き継ぎの子は入らない [DU-27]")
    func decliningInheritanceOmitsThoseChildren() async {
        let kinds = await MainActor.run { () -> [String] in
            let loss = DuplicateLossReport(labelsOnlyOnDoomed: [Self.label(20): "引き継ぐ"],
                                           bestDoomedRating: 4, keeperRating: 0)
            let command = DuplicateResolutionModel.makeDeleteCommand(
                plan: Self.plan(keeper: Self.row(1, name: "残す.cbz"),
                                doomed: [Self.row(2, name: "捨てる.cbz")], loss: loss),
                inheritMetadata: false, services: LibraryServices.shared)
            return command.children.map { String(describing: type(of: $0)) }
        }
        #expect(!kinds.contains { $0.contains("AssignLabel") })
        #expect(!kinds.contains { $0.contains("SetRating") })
    }

    /// 残す側に評価が付いていれば、引き継ぎのコマンドを**組み立てない**。
    ///
    /// `DuplicateLossReport` 側の判定とは別に、**組み立て側でも守る**
    /// ——片方だけ直したときに、画面は「引き継ぐものはありません」と
    /// 言いながら評価だけ黙って上書きされる、という形になりうる。
    @Test("残す側が評価済みなら評価のコマンドを作らない [DU-27]")
    func anExistingRatingProducesNoRatingCommand() async {
        let kinds = await MainActor.run { () -> [String] in
            let loss = DuplicateLossReport(labelsOnlyOnDoomed: [:],
                                           bestDoomedRating: 5, keeperRating: 2)
            return DuplicateResolutionModel.makeDeleteCommand(
                plan: Self.plan(keeper: Self.row(1, name: "残す.cbz", rating: 2),
                                doomed: [Self.row(2, name: "捨てる.cbz", rating: 5)],
                                loss: loss),
                inheritMetadata: true, services: LibraryServices.shared)
                .children.map { String(describing: type(of: $0)) }
        }
        #expect(!kinds.contains { $0.contains("SetRating") },
                "★2 を ★5 で黙って上書きしない")
    }

    /// **ゴミ箱を使えない場所では取り消せない** [PD-05][NV4-01]。
    ///
    /// `CompositeCommand.isUndoable` は子の `allSatisfy` なので自動的に偽に
    /// なるが、**確認の文言がこの性質に基づいている**ので、ずれると
    /// いちばん取り返しのつかない場面で嘘をつく（`FileVaultModel` と同じ）。
    @Test("ゴミ箱が使えるかで取り消せるかが変わる [DU-24][PD-05]")
    func undoabilityFollowsWhetherTrashIsAvailable() async {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = [Self.row(2, name: "捨てる.cbz")]
        let (withTrash, without) = await MainActor.run { () -> (Bool, Bool) in
            (DuplicateResolutionModel.makeDeleteCommand(
                plan: Self.plan(keeper: keeper, doomed: doomed, usesTrash: true),
                inheritMetadata: false, services: LibraryServices.shared).isUndoable,
             DuplicateResolutionModel.makeDeleteCommand(
                plan: Self.plan(keeper: keeper, doomed: doomed, usesTrash: false),
                inheritMetadata: false, services: LibraryServices.shared).isUndoable)
        }
        #expect(withTrash)
        #expect(!without)
    }

    @Test("削除の対象は残す 1 件を除いた全部 [DU-24]")
    func everythingButTheKeeperIsDeleted() async {
        let model = await DuplicateResolutionModel()
        await MainActor.run {
            model.seedForTesting(rows: [Self.row(1, name: "a.cbz"),
                                        Self.row(2, name: "b.cbz"),
                                        Self.row(3, name: "c.cbz")],
                                 keepID: FileID(rawValue: 2))
            #expect(model.doomed.map(\.id.rawValue) == [1, 3])
            #expect(model.canDelete)
        }
    }
}
