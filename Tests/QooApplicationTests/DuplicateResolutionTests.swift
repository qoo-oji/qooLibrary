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
            assignments: [keeper.id: [Self.label(10)],
                          doomed.id: [Self.label(10), Self.label(20)]],
            names: [Self.label(10): "共通", Self.label(20): "捨てる側だけ"])
        #expect(report.labelsOnlyOnDoomed == [Self.label(20): "捨てる側だけ"])
    }

    /// **残す側で保護されたフィールドへは引き継がない** [PR-02][DU-27]。
    ///
    /// 保護は「このフィールドの状態は利用者が決めた」という意味なので、
    /// 捨てる側に付いているからといって足すと、外したはずのラベルが復活する
    /// ——しかも復活したことは画面から読み取れない。
    @Test("残す側で保護されたフィールドのラベルは引き継がない [DU-27][PR-02]")
    func labelsInProtectedFieldsAreNotInherited() {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = Self.row(2, name: "捨てる.cbz")
        let group = LabelGroupID(rawValue: 7)
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, doomed],
            assignments: [keeper.id: [], doomed.id: [Self.label(40)]],
            names: [Self.label(40): "捨てる側だけ"],
            groupByLabel: [Self.label(40): group],
            keeperProtections: [.field(group)])
        #expect(report.labelsOnlyOnDoomed.isEmpty)
    }

    @Test("保護されていないフィールドなら引き継ぐ [DU-27]")
    func labelsInUnprotectedFieldsAreInherited() {
        let keeper = Self.row(1, name: "残す.cbz")
        let doomed = Self.row(2, name: "捨てる.cbz")
        let group = LabelGroupID(rawValue: 7)
        let report = DuplicateLossReport.make(
            keepID: keeper.id, rows: [keeper, doomed],
            assignments: [keeper.id: [], doomed.id: [Self.label(40)]],
            names: [Self.label(40): "捨てる側だけ"],
            groupByLabel: [Self.label(40): group],
            keeperProtections: [])
        #expect(report.labelsOnlyOnDoomed == [Self.label(40): "捨てる側だけ"])
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
        // 引き継ぎコマンドはラベルのフィールドを要る [PR-03] ので、
        // 失われるラベルぶんの対応を作っておく。
        DuplicateDeletePlan(
            keeper: keeper, doomed: doomed, usesTrash: usesTrash, loss: loss,
            groupByLabel: loss.labelsOnlyOnDoomed.keys.reduce(into: [:]) {
                $0[$1] = LabelGroupID(rawValue: 1)
            })
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
