//
//  ファイル保管庫の整理ウインドウの判定 [FAW-01〜FAW-05][15.4 節]。
//
//  一覧の組み立て・並べ替え・検索・既定のライブラリはすべて純粋関数なので、
//  ここで直に固定する（`LabelVaultModel` のテストと同じ形）。
//
import Testing
import Foundation
import QooInfrastructure
import QooKit
@testable import QooApplication

@Suite("ファイル保管庫の整理 [FAW-01〜FAW-05]")
struct FileVaultModelTests {

    private static func archived(_ relativePath: String, id: Int64,
                                 from: String? = nil, at: Date? = nil,
                                 labels: Int = 0,
                                 isArchived: Bool = true) -> ArchivedFile {
        let row = FileRow(
            id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
            relativePath: relativePath,
            filename: (relativePath as NSString).lastPathComponent,
            fileSize: 100, createdAt: .distantPast, modifiedAt: .distantPast,
            title: nil, seriesName: nil, volume: VolumeValue(kind: .none, number: nil, raw: nil),
            rating: 0, state: .active, isArchived: isArchived,
            archivedFromPath: from, archivedAt: at, isBookFolder: false)
        return ArchivedFile(row: row, labelCount: labels)
    }

    private static func library(_ id: Int64, online: Bool = true) -> LibrarySummary {
        LibrarySummary(id: LibraryID(rawValue: id), uuid: UUID(), displayName: "L\(id)",
                       resolvedPath: "/tmp/lib\(id)", volumeUUID: "V",
                       libraryTypeID: LibraryTypeID(rawValue: 0), libraryTypeName: "T",
                       isOnline: online, isReadOnlyDueToFS: false, fileCount: 0,
                       settingsRevision: 0)
    }

    // MARK: - 元フォルダごとの区画 [FAW-01][FDA-05]

    @Test("元のフォルダごとに分ける [FAW-01][15.4 節]")
    func groupsByOriginalFolder() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/作者A/x.cbz", id: 1, from: "作者A/x.cbz"),
            Self.archived(".qooarchive/作者B/y.cbz", id: 2, from: "作者B/y.cbz"),
            Self.archived(".qooarchive/作者A/z.cbz", id: 3, from: "作者A/z.cbz"),
        ], sortedBy: .name, matching: "")

        #expect(sections.map(\.folder) == ["作者A", "作者B"])
        #expect(sections[0].rows.map(\.row.filename) == ["x.cbz", "z.cbz"])
    }

    /// **フォルダごと移した場合もファイル単位** [FAW-01][FDA-05]。記録が無くても
    /// 現在のパスから元のフォルダを導ける [FA-03]。
    @Test("記録が無くても現在のパスから元フォルダを導く [FA-03]")
    func derivesTheFolderWhenTheRecordIsMissing() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/作者A/x.cbz", id: 1),
        ], sortedBy: .name, matching: "")
        #expect(sections.map(\.folder) == ["作者A"])
    }

    @Test("ライブラリ直下は空の見出しになる")
    func filesAtTheLibraryRootFormTheirOwnSection() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/x.cbz", id: 1),
        ], sortedBy: .name, matching: "")
        #expect(sections.map(\.folder) == [""])
    }

    /// **不変条件を関数自身が守る。** 保管庫の画面に保管庫外のファイルが
    /// 混ざるのは、意味そのものが壊れた状態になる。
    @Test("保管庫にないファイルは通さない")
    func rejectsFilesOutsideTheVault() {
        let sections = FileVaultModel.sections(files: [
            Self.archived("作者A/x.cbz", id: 1, isArchived: false),
        ], sortedBy: .name, matching: "")
        #expect(sections.isEmpty)
    }

    // MARK: - 並べ替え [FAW-05]

    @Test("しまった日時で並べ替える（新しいものから）[FAW-05]")
    func sortsByArchivedDate() {
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let recent = Date(timeIntervalSinceReferenceDate: 900)
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/A/古い.cbz", id: 1, from: "A/古い.cbz", at: old),
            Self.archived(".qooarchive/A/新しい.cbz", id: 2, from: "A/新しい.cbz", at: recent),
        ], sortedBy: .archivedAt, matching: "")
        #expect(sections[0].rows.map(\.row.filename) == ["新しい.cbz", "古い.cbz"])
    }

    /// **日時が無い行は末尾へ。** 先頭に集めると「いつしまったか分からない
    /// もの」が最初に目に入る。
    @Test("日時の記録が無い行は末尾へ [FA-04]")
    func rowsWithoutADateSortLast() {
        let when = Date(timeIntervalSinceReferenceDate: 100)
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/A/記録なし.cbz", id: 1),
            Self.archived(".qooarchive/A/記録あり.cbz", id: 2, at: when),
        ], sortedBy: .archivedAt, matching: "")
        #expect(sections[0].rows.map(\.row.filename) == ["記録あり.cbz", "記録なし.cbz"])
    }

    @Test("並べ替えは区画をまたがない [15.4 節]")
    func sortingStaysInsideItsSection() {
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let recent = Date(timeIntervalSinceReferenceDate: 900)
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/作者A/古い.cbz", id: 1, from: "作者A/古い.cbz", at: old),
            Self.archived(".qooarchive/作者B/新しい.cbz", id: 2, from: "作者B/新しい.cbz", at: recent),
        ], sortedBy: .archivedAt, matching: "")
        // 全体順なら 作者B が先頭に来るが、区画の順序は元フォルダの自然順。
        #expect(sections.map(\.folder) == ["作者A", "作者B"])
    }

    // MARK: - 検索

    @Test("全角で打っても半角のファイル名に当たる [LE-12 と同じ判定]")
    func searchIsWidthInsensitive() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/A/STUDIO abc.cbz", id: 1, from: "A/STUDIO abc.cbz"),
        ], sortedBy: .name, matching: "ＡＢＣ")
        #expect(sections.count == 1)
    }

    @Test("元のフォルダ名でも探せる")
    func searchAlsoMatchesTheOriginalFolder() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/作者A/x.cbz", id: 1, from: "作者A/x.cbz"),
            Self.archived(".qooarchive/作者B/y.cbz", id: 2, from: "作者B/y.cbz"),
        ], sortedBy: .name, matching: "作者A")
        #expect(sections.map(\.folder) == ["作者A"])
    }

    /// **見出しだけが残らない。** 何のための区画か読めなくなる。
    @Test("検索で 0 件になった区画は落とす")
    func emptySectionsAreDropped() {
        let sections = FileVaultModel.sections(files: [
            Self.archived(".qooarchive/作者A/x.cbz", id: 1, from: "作者A/x.cbz"),
        ], sortedBy: .name, matching: "一致しない語")
        #expect(sections.isEmpty)
    }

    // MARK: - 削除の組み立て [FAW-03][NV4-01]

    /// **ゴミ箱がある場所とない場所で、取り消せるかどうかが変わる**
    /// ［実機検証で発見］。以前は `TrashCommand` を直に呼んでおり、
    /// **ゴミ箱を持たない場所では削除が丸ごと失敗していた**——しかも
    /// 「『すぐに削除』をお使いください」と案内されるのに、この画面には
    /// その項目が無いという行き止まりだった。
    ///
    /// **共有だけの話ではない。** `TrashAvailability` は `.trashDirectory` を
    /// `create: false` で尋ねるので、**まだ一度も何も捨てていない外付け
    /// ボリュームでも「ゴミ箱なし」になる**（1-17 の実測、8章 §8.7.1）。
    @MainActor
    @Test("ゴミ箱があるなら取り消せる [FAW-03]")
    func deletingThroughTheTrashStaysUndoable() async throws {
        let w = try ServicesWorkspace()
        let plan = DeletePlan(files: [Self.archived(".qooarchive/A/x.cbz", id: 1)],
                              usesTrash: true)
        let command = FileVaultModel.makeDeleteCommand(
            plan: plan, displayName: "削除", items: [URL(fileURLWithPath: "/tmp/x.cbz")],
            services: w.services)
        #expect(command.isUndoable)
    }

    /// **完全削除は取り消せない** [PD-05]。`CompositeCommand.isUndoable` は
    /// 子の `allSatisfy` なので、ここが自動的に偽になる——確認ダイアログの
    /// 「この操作は取り消せません」はこの性質に基づいている。
    @MainActor
    @Test("ゴミ箱が無ければ取り消せない [NV4-01][PD-05]")
    func deletingWithoutATrashIsNotUndoable() async throws {
        let w = try ServicesWorkspace()
        let plan = DeletePlan(files: [Self.archived(".qooarchive/A/x.cbz", id: 1)],
                              usesTrash: false)
        let command = FileVaultModel.makeDeleteCommand(
            plan: plan, displayName: "削除", items: [URL(fileURLWithPath: "/tmp/x.cbz")],
            services: w.services)
        #expect(!command.isUndoable)
    }

    /// **実体を捨てる → 記録を消す、の順** [FAW-03]。逆にすると、捨てるほうに
    /// 失敗したときに記録だけが消えて実体が保管庫に残る（次の走査でラベルを
    /// 失った行として戻ってくる）。`CompositeCommand` は子が投げるとそこで
    /// 止めるので、この順序が守られている限り「記録だけ消えた」は起こらない。
    @MainActor
    @Test("実体を捨ててから記録を消す [FAW-03]")
    func removalRunsBeforeTheRecordIsDeleted() async throws {
        let w = try ServicesWorkspace()
        let plan = DeletePlan(files: [Self.archived(".qooarchive/A/x.cbz", id: 1)],
                              usesTrash: true)
        let command = FileVaultModel.makeDeleteCommand(
            plan: plan, displayName: "削除", items: [URL(fileURLWithPath: "/tmp/x.cbz")],
            services: w.services)
        #expect(command.children.first is TrashCommand)
        #expect(command.children.last is DeleteOrphanedFilesCommand)
    }

    // MARK: - 既定のライブラリ

    @Test("指定されたライブラリが最優先（空でも）")
    func preferredLibraryWins() {
        let libraries = [Self.library(1), Self.library(2)]
        let chosen = FileVaultModel.defaultLibrary(
            from: libraries, archivedCounts: [LibraryID(rawValue: 2): 3],
            preferring: LibraryID(rawValue: 1))
        #expect(chosen == LibraryID(rawValue: 1))
    }

    /// 素直に先頭を選ぶと、保管庫が空のライブラリに着地して行き止まりになる。
    @Test("指定が無ければ中身のある最初のライブラリ")
    func fallsBackToThePopulatedLibrary() {
        let libraries = [Self.library(1), Self.library(2)]
        let chosen = FileVaultModel.defaultLibrary(
            from: libraries, archivedCounts: [LibraryID(rawValue: 2): 3], preferring: nil)
        #expect(chosen == LibraryID(rawValue: 2))
    }

    @Test("どこにも無ければ先頭へ落とす")
    func fallsBackToTheFirstLibrary() {
        let libraries = [Self.library(1), Self.library(2)]
        let chosen = FileVaultModel.defaultLibrary(from: libraries, archivedCounts: [:],
                                                    preferring: nil)
        #expect(chosen == LibraryID(rawValue: 1))
    }
}

@Suite("保管庫のメニューの向き [FA-01][FA-07]")
struct VaultDirectionTests {

    @Test("外にあるものだけなら「入れる」")
    func allOutsideMeansArchive() {
        #expect(VaultDirection.forSelection(["A/x.cbz", "B/y.cbz"]) == true)
    }

    @Test("中にあるものだけなら「出す」")
    func allInsideMeansRestore() {
        #expect(VaultDirection.forSelection([".qooarchive/A/x.cbz"]) == false)
    }

    /// **混ざっているときは出さない。** 「入れる」と「出す」が同時に走る
    /// 1 つの項目は、押した結果が読めない。
    @Test("混ざっていたら出さない")
    func mixedSelectionOffersNothing() {
        #expect(VaultDirection.forSelection(["A/x.cbz", ".qooarchive/B/y.cbz"]) == nil)
    }

    @Test("空の選択には出さない")
    func emptySelectionOffersNothing() {
        #expect(VaultDirection.forSelection([]) == nil)
    }
}

@Suite("保管庫コマンドの行き先 [FA-02][FA-03][FA-04]")
struct SetFileArchivedCommandDestinationTests {

    @Test("入れるときは階層を写した場所へ [FA-02][FA-03]")
    func archivingMirrorsTheHierarchy() {
        let target = SetFileArchivedCommand.Target(id: FileID(rawValue: 1),
                                                   relativePath: "作者A/x.cbz")
        #expect(SetFileArchivedCommand.destination(for: target, archived: true)
                == ".qooarchive/作者A/x.cbz")
    }

    /// **記録があればそこへ** [FA-04]。連番が付いて入った [FA-13] 場合、
    /// 現在のパスから導いた値とは食い違う——記録のほうが正しい。
    @Test("戻すときは記録された元の場所へ [FA-04]")
    func restoringUsesTheRecordedOrigin() {
        let target = SetFileArchivedCommand.Target(
            id: FileID(rawValue: 1), relativePath: ".qooarchive/作者A/x 2.cbz",
            archivedFromPath: "作者A/x.cbz")
        #expect(SetFileArchivedCommand.destination(for: target, archived: false)
                == "作者A/x.cbz")
    }

    /// 外部（Finder 等）で `.qooarchive` へ入れられたものは記録を持たない。
    @Test("記録が無ければ現在のパスから導く [FA-03]")
    func restoringDerivesTheOriginWhenUnrecorded() {
        let target = SetFileArchivedCommand.Target(id: FileID(rawValue: 1),
                                                   relativePath: ".qooarchive/作者A/x.cbz")
        #expect(SetFileArchivedCommand.destination(for: target, archived: false)
                == "作者A/x.cbz")
    }

    @Test("既にその側にあるなら運ばない")
    func nothingToDoWhenAlreadyOnThatSide() {
        let inside = SetFileArchivedCommand.Target(id: FileID(rawValue: 1),
                                                   relativePath: ".qooarchive/A/x.cbz")
        #expect(SetFileArchivedCommand.destination(for: inside, archived: true) == nil)
        let outside = SetFileArchivedCommand.Target(id: FileID(rawValue: 2),
                                                    relativePath: "A/x.cbz")
        #expect(SetFileArchivedCommand.destination(for: outside, archived: false) == nil)
    }

    /// **素の `hasPrefix` では誤る**——`a/bc/x` が `a/b` の配下に見える。
    @Test("フォルダ配下の切り出しは成分の境界で行う [FDA-01]")
    func folderSuffixRespectsComponentBoundaries() {
        #expect(ArchiveFolderCommand.suffix(of: "A/B/x.cbz", under: "A/B") == "x.cbz")
        #expect(ArchiveFolderCommand.suffix(of: "A/BC/x.cbz", under: "A/B") == nil)
        // フォルダ自身の行（ブックフォルダ [IF-01]）は残りが空になる。
        #expect(ArchiveFolderCommand.suffix(of: "A/B", under: "A/B") == "")
    }
}
