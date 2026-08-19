import Testing
import Foundation
@testable import QooKit

//
//  設定を実ファイル名へ当てるプレビュー [HP-05]。
//
//  **標本は実際に扱う形にする**——`(同人誌) [サークル] 題` のような、この分野で
//  最も普通の名前。きれいな例だけで固めると、現実の入力を取りこぼす形の
//  不具合が素通りする（匿名化テストで実際に踏んだ教訓）。値はすべて合成名。
//
@Suite("有効化プレビュー [HP-05]")
struct LibraryPreviewTests {

    private static func doujinDraft() throws -> LibrarySettingsDraft {
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-a" })
        return TemplateInstantiation.draft(
            from: template, volumeSets: try BuiltInTemplates.volumeSets(),
            displayName: "テスト")
    }

    @Test("一致した件数と未解決の件数を数える")
    func countsMatchesAndUnresolved() throws {
        let draft = try Self.doujinDraft()
        let outcome = LibraryPreview.run(filenames: [
            "(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).zip",
            "まったく形式に合わない名前.zip",
        ], draft: draft)

        #expect(outcome.total == 2)
        #expect(outcome.matched == 1)
        #expect(outcome.unresolved == 1)
        #expect(outcome.matchRate == 0.5)
    }

    @Test("未解決を先頭に集める [ユーザー判断]")
    func unresolvedComesFirst() throws {
        let draft = try Self.doujinDraft()
        let outcome = LibraryPreview.run(filenames: [
            "(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).zip",
            "合わない名前.zip",
            "(同人誌) [サークル値B (著者値B)] 作品名B (イベント値2).zip",
        ], draft: draft)

        #expect(outcome.items.first?.filename == "合わない名前.zip")
        #expect(outcome.items.first?.matched == false)
        // 同じ区分の中では入力順を保つ。
        #expect(outcome.items.dropFirst().map(\.id) == [0, 2])
    }

    @Test("実際に付くラベルを見せる [AL-01]")
    func showsTheLabelsThatWillBeAssigned() throws {
        let draft = try Self.doujinDraft()
        let outcome = LibraryPreview.run(
            filenames: ["(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).zip"], draft: draft)

        let item = try #require(outcome.items.first)
        #expect(item.matched)
        let values = item.fields.map(\.value)
        #expect(values.contains("作品名A"), "タイトルが出ていない")
        #expect(values.contains("サークル値A"), "サークルのラベルが出ていない")
        #expect(values.contains("著者値A"), "著者のラベルが出ていない")
        // ラベルはグループ番号つきで返る——表示名の解決は UI 層の仕事。
        #expect(item.fields.contains { if case .labelGroup = $0.ref { true } else { false } })
    }

    @Test("巻数は原文表記で見せる [SE-02]")
    func volumeKeepsItsRawText() throws {
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.general-comic-a" })
        let draft = TemplateInstantiation.draft(
            from: template, volumeSets: try BuiltInTemplates.volumeSets(), displayName: "テスト")
        let outcome = LibraryPreview.run(
            filenames: ["[著者値A] 作品名A 第03巻.zip"], draft: draft)

        let item = try #require(outcome.items.first)
        let volume = item.fields.first { $0.ref == .volume }
        #expect(volume?.value == "第03巻", "数値へ畳んだ値だけだと、どこを巻数と読んだか分からない")
    }

    /// 白紙は**どのファイル名にも一致しない**のが正しい [LT-02]。
    /// 「まだ何も決めていない」を素直に表す。
    @Test("白紙の草案では全件が未解決になる")
    func blankDraftResolvesNothing() throws {
        let draft = TemplateInstantiation.blankDraft(
            volumeSets: try BuiltInTemplates.volumeSets(),
            displayName: "白紙", defaultLabelGroupName: "ラベル")
        let outcome = LibraryPreview.run(filenames: ["何でもよい名前.zip"], draft: draft)
        #expect(outcome.matched == 0)
        #expect(outcome.unresolved == 1)
    }

    /// 編集の途中でフォーマットが壊れているのは**普通の状態**。そこで
    /// 例外にすると、直している最中はプレビューが一切出せなくなる。
    @Test("壊れたフォーマットがあってもプレビューは出る [HP-05]")
    func brokenFormatDoesNotStopThePreview() throws {
        var draft = try Self.doujinDraft()
        draft.filenameFormats.append(FilenameFormatDraft(source: "@@@壊れている["))
        let outcome = LibraryPreview.run(
            filenames: ["(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).zip"], draft: draft)
        #expect(outcome.matched == 1)
    }

    /// **型不一致は「他のライブラリの型名に当たった」ときに立つ** [TY-01]。
    ///
    /// `@librarytype` は型付き照合なので、候補は
    /// `allLibraryTypeNames`（＝このライブラリの型名 ＋ 他ライブラリの型名）
    /// に限られる。どれにも当たらなければ単に不一致（未解決）で、
    /// **当たったが自分の型名ではなかった**ときだけ警告になる——
    /// 「同人誌のライブラリに成年コミックのファイルが混ざっている」形の検出。
    @Test("他のライブラリの型名に当たったら警告として数える [TY-01]")
    func countsLibraryTypeMismatch() throws {
        let template = try #require(try BuiltInTemplates.libraryTypes()
            .first { $0.key == "builtin.doujinshi-a" })
        var draft = TemplateInstantiation.draft(
            from: template, volumeSets: try BuiltInTemplates.volumeSets(),
            displayName: "テスト", otherLibraryTypeNames: ["成年コミック"])
        draft.filenameFormats = [FilenameFormatDraft(source: "(@librarytype) @title")]

        // 自分の型名なら警告は出ない（対照）。
        let ok = LibraryPreview.run(filenames: ["(同人誌) 作品名A.zip"], draft: draft)
        #expect(ok.matched == 1)
        #expect(ok.libraryTypeMismatched == 0)

        // 他のライブラリの型名に当たった場合。取り込みはされる
        // （`purpose: .preview` は弾かない）が、印を付けて目立たせる。
        let mismatched = LibraryPreview.run(filenames: ["(成年コミック) 作品名A.zip"], draft: draft)
        #expect(mismatched.matched == 1)
        #expect(mismatched.libraryTypeMismatched == 1)

        // どの型名にも当たらなければ未解決。
        let unknown = LibraryPreview.run(filenames: ["(知らない型) 作品名A.zip"], draft: draft)
        #expect(unknown.unresolved == 1)
    }

    /// **走査と同じ条件で絞る** [AL-11][IF-01]。
    ///
    /// 実機で、プレビューが「12 件中 4 件が未解決」と出したのに走査は
    /// 「3 件が未解決」と報告し、差の 1 件（`メモ.txt`）が何なのか
    /// 分からなかった——絞らずに数えていたのが原因。
    @Test("対象拡張子でないファイルは試さず、除いた件数として数える")
    func filtersByTargetExtensions() throws {
        var draft = try Self.doujinDraft()
        draft.targetExtensions = ["cbz"]
        let outcome = LibraryPreview.run(filenames: [
            "(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).cbz",
            "メモ.txt",
            "画像.jpg",
        ], draft: draft)

        #expect(outcome.total == 1, "対象拡張子のものだけを試す")
        #expect(outcome.matched == 1)
        #expect(outcome.unresolved == 0)
        #expect(outcome.excluded == 2)
        #expect(outcome.items.count == 1)
    }

    /// 空集合は「すべてが対象」の意味 [`LibraryEnumerator` の解釈]。
    /// **空を「何も対象でない」と読むと、プレビューが常に 0 件になる。**
    @Test("対象拡張子が空ならすべてを試す [AL-11]")
    func emptyTargetExtensionsMeansEverything() throws {
        var draft = try Self.doujinDraft()
        draft.targetExtensions = []
        let outcome = LibraryPreview.run(filenames: ["メモ.txt", "画像.jpg"], draft: draft)
        #expect(outcome.total == 2)
        #expect(outcome.excluded == 0)
    }

    /// 拡張子を足したらプレビューが変わること。**絞らない実装では
    /// 「拡張子を編集しても結果が変わらない」**ので、編集の効果が見えない。
    @Test("対象拡張子を足すと試す件数が増える")
    func addingAnExtensionWidensThePreview() throws {
        var draft = try Self.doujinDraft()
        draft.targetExtensions = ["cbz"]
        let names = ["(同人誌) [サークル値A (著者値A)] 作品名A (イベント値1).cbz",
                     "(同人誌) [サークル値B (著者値B)] 作品名B (イベント値1).zip"]
        #expect(LibraryPreview.run(filenames: names, draft: draft).total == 1)

        draft.targetExtensions = ["cbz", "zip"]
        let widened = LibraryPreview.run(filenames: names, draft: draft)
        #expect(widened.total == 2)
        #expect(widened.matched == 2)
        #expect(widened.excluded == 0)
    }

    @Test("明細の件数は上限で打ち切るが、集計は全件で行う")
    func summaryCoversEverythingEvenWhenTheListIsCapped() throws {
        let draft = try Self.doujinDraft()
        let names = (0..<50).map { "(同人誌) [サークル値A (著者値A)] 作品名\($0) (イベント値1).zip" }
        let outcome = LibraryPreview.run(filenames: names, draft: draft, displayLimit: 10)
        #expect(outcome.total == 50)
        #expect(outcome.matched == 50)
        #expect(outcome.items.count == 10)
    }
}
