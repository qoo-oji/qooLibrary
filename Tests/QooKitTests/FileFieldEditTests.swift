import Foundation
import Testing
@testable import QooKit

//
//  右ペインから書き換える値 [RP-10〜RP-12][CV-02〜CV-08]。
//

@Suite("タイトル・カバーの編集値 [RP-10〜RP-12][CV-02〜CV-08]")
struct FileFieldEditTests {

    private func row(title: String? = nil, origin: ValueOrigin = .auto,
                     coverRef: String? = nil, coverSource: CoverSource = .auto) -> FileRow {
        FileRow(id: FileID(rawValue: 1), libraryID: LibraryID(rawValue: 1),
                relativePath: "作品名A 第01巻.cbz", filename: "作品名A 第01巻.cbz",
                fileSize: 1, createdAt: .distantPast, modifiedAt: .distantPast,
                title: title, titleOrigin: origin, seriesName: "作品名A",
                volume: .numeric(1, raw: "第01巻"), authorName: "著者値A", rating: 0,
                coverImageRef: coverRef, coverImageSource: coverSource,
                state: .active, isArchived: false, isBookFolder: false)
    }

    // MARK: - タイトル [RP-10][RP-11]

    @Test("手動編集は origin を manual にする [RP-11]")
    func manualEditMarksOrigin() {
        let edit = FileFieldEdit(row(title: "自動値", origin: .auto)).settingTitle("手で付けた題")
        #expect(edit.title == "手で付けた題")
        #expect(edit.titleOrigin == .manual)
    }

    /// **他の列を巻き添えにしない。** タイトルを直しただけでシリーズ名や著者が
    /// 消えると、取り消すまで気づけない。
    @Test("タイトル編集は他のフィールドを変えない")
    func manualEditKeepsOtherFields() {
        let before = FileFieldEdit(row())
        let after = before.settingTitle("題")
        #expect(after.seriesName == before.seriesName)
        #expect(after.volume == before.volume)
        #expect(after.authorName == before.authorName)
    }

    @Test("前後の空白は落とす")
    func trimsWhitespace() {
        #expect(FileFieldEdit(row()).settingTitle("  題  ").title == "題")
    }

    /// 空欄にしたら「未設定」に戻すが、**`manual` の印は残す**——自動抽出値を
    /// 使わないという意思表示そのものが RP-11 の対象。
    @Test("空欄は未設定にするが manual の印は残す [RP-11]")
    func blankClearsTitleButKeepsManual() {
        let edit = FileFieldEdit(row(title: "自動値", origin: .auto)).settingTitle("   ")
        #expect(edit.title == nil)
        #expect(edit.titleOrigin == .manual)
    }

    @Test("行から写した値は行と一致する")
    func copiesFromRow() {
        let edit = FileFieldEdit(row(title: "題", origin: .manual))
        #expect(edit.title == "題")
        #expect(edit.titleOrigin == .manual)
        #expect(edit.seriesName == "作品名A")
        #expect(edit.authorName == "著者値A")
    }

    // MARK: - カバー [CV-02][CV-07]

    @Test("既定に戻した割り当ては参照を持たない [CV-07]")
    func automaticHasNoRef() {
        #expect(CoverAssignment.automatic.source == .auto)
        #expect(CoverAssignment.automatic.ref == nil)
    }

    @Test("ユーザー指定の割り当ては参照を持つ [CV-06]")
    func userSpecifiedCarriesRef() {
        let assignment = CoverAssignment.userSpecified(ref: "abc.png")
        #expect(assignment.source == .userSpecified)
        #expect(assignment.ref == "abc.png")
    }

    @Test("行から写した割り当ては行と一致する")
    func copiesAssignmentFromRow() {
        let assignment = CoverAssignment(row(coverRef: "x.jpg", coverSource: .userSpecified))
        #expect(assignment == CoverAssignment.userSpecified(ref: "x.jpg"))
    }
}
