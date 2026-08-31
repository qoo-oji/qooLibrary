import Foundation
import Testing
@testable import QooKit

//
//  右ペインから書き換える値 [RP-10〜RP-12][CV-02〜CV-08]。
//

@Suite("タイトル・カバーの編集値 [RP-10〜RP-12][CV-02〜CV-08]")
struct FileFieldEditTests {

    private func row(title: String? = nil, protected: Set<ProtectionScope> = [],
                     coverRef: String? = nil, coverSource: CoverSource = .auto) -> FileRow {
        FileRow(id: FileID(rawValue: 1), libraryID: LibraryID(rawValue: 1),
                relativePath: "作品名A 第01巻.cbz", filename: "作品名A 第01巻.cbz",
                fileSize: 1, createdAt: .distantPast, modifiedAt: .distantPast,
                title: title, protectedScopes: protected, seriesName: "作品名A",
                volume: .numeric(1, raw: "第01巻"), authorName: "著者値A", rating: 0,
                coverImageRef: coverRef, coverImageSource: coverSource,
                state: .active, isArchived: false, isBookFolder: false)
    }

    // MARK: - タイトル [RP-10][RP-11]

    /// **編集の印は値型が持たない** [PR-03]。保護を立てるのはコマンド
    /// （`SetFileFieldsCommand`）の仕事で、この型は値だけを運ぶ。
    @Test("タイトルの差し替えは値だけを変える [RP-10]")
    func manualEditReplacesTitle() {
        let edit = FileFieldEdit(row(title: "自動値")).settingTitle("手で付けた題")
        #expect(edit.title == "手で付けた題")
    }

    @Test("シリーズ名・巻数も同じ形で差し替えられる [RP-13][RP-14]")
    func editsSeriesAndVolume() {
        let base = FileFieldEdit(row())
        #expect(base.settingSeriesName("  別のシリーズ  ").seriesName == "別のシリーズ")
        #expect(base.settingSeriesName("   ").seriesName == nil)
        let volume = try? #require(VolumeValue.parsingUserInput("３"))
        #expect(volume?.number == 3, "全角も読む")
        #expect(VolumeValue.parsingUserInput("") == VolumeValue.none)
        #expect(VolumeValue.parsingUserInput("巻数") == nil, "読めない入力は受け付けない")
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

    /// 空欄にしたら「未設定」に戻す。**自動値へは戻らない**——保護が
    /// 立っている限り走査は触れない [PR-01] ので、「自動抽出値を使わない」と
    /// いう意思表示は保たれる。
    @Test("空欄は未設定にする [RP-10]")
    func blankClearsTitle() {
        #expect(FileFieldEdit(row(title: "自動値")).settingTitle("   ").title == nil)
    }

    @Test("行から写した値は行と一致する")
    func copiesFromRow() {
        let edit = FileFieldEdit(row(title: "題"))
        #expect(edit.title == "題")
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
