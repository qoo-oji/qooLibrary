import Foundation
import Testing

@testable import QooKit

/// プリセット改訂の差分 [LT-10〜LT-17]。
///
/// 標本は**実際のプリセットの形**にする——`(@booktype) [@author] @title` の
/// ような予約語入りのフォーマットと、1〜7 の既定フィールド。きれいな例だけを
/// 標本にすると、その分野で最も普通の入力を取りこぼす（CLAUDE.md の教訓）。
struct TemplateDiffTests {

    // MARK: - 標本

    private static func field(_ index: Int, _ name: String,
                              auto: Bool? = nil) -> LibraryTypeTemplate.FieldSpec {
        LibraryTypeTemplate.FieldSpec(index: index, name: name, autoAssign: auto)
    }

    private static func template(version: Int,
                                 fields: [LibraryTypeTemplate.FieldSpec],
                                 bindings: [String: Int],
                                 formats: [String],
                                 folderLevels: [String: LibraryTypeTemplate.FolderLevelSpec] = [:],
                                 volumeSet: String = "VS") -> LibraryTypeTemplate
    {
        LibraryTypeTemplate(
            key: "builtin.sample", displayName: "見本", libraryTypeName: "見本",
            version: version, labelGroups: fields, semanticBindings: bindings,
            folderLevels: folderLevels, filenameFormats: formats, volumeSet: volumeSet)
    }

    private static let volumeSets = VolumeSetDefinition(sets: [
        "VS": [.init(source: #"第(\d+)巻"#, kind: nil)],
        "VS2": [.init(source: #"第(\d+)巻"#, kind: nil),
                .init(source: #"(?i:vol)\.?\s*(\d+)"#, kind: nil)],
    ])

    /// 登録時のプリセット（v1）。既定フィールド 3 種＋フォーマット 2 本。
    private static let base = template(
        version: 1,
        fields: [field(1, "著者"), field(2, "サークル"), field(3, "ジャンル")],
        bindings: ["@author": 1, "@circle": 2, "@genre": 3],
        formats: ["[@author] @title", "@title"])

    /// 改訂後（v2）。**本の種別フィールドが増え**、フォーマットが 1 本増えた
    /// ——v2.14 で実際に起きた改訂と同じ形。
    private static let latest = template(
        version: 2,
        fields: [field(1, "著者"), field(2, "サークル"), field(3, "ジャンル"),
                 field(7, "本の種別")],
        bindings: ["@author": 1, "@circle": 2, "@genre": 3, "@booktype": 7],
        formats: ["(@booktype) [@author] @title", "[@author] @title", "@title"])

    private static func currentDraft(
        from template: LibraryTypeTemplate = base) -> LibrarySettingsDraft
    {
        TemplateInstantiation.draft(from: template, volumeSets: volumeSets, displayName: "蔵書")
    }

    private static func diff(current: LibrarySettingsDraft,
                             base: LibraryTypeTemplate = base,
                             latest: LibraryTypeTemplate = latest) -> TemplateDiff
    {
        TemplateDiffBuilder.diff(base: base, latest: latest,
                                 current: current, volumeSets: volumeSets)
    }

    // MARK: - 検出

    /// 改訂がそのまま反映された未編集のライブラリでは、増えたぶんだけが出る。
    @Test func detectsAddedFieldAndFormat() {
        let d = Self.diff(current: Self.currentDraft())
        #expect(d.fromVersion == 1 && d.toVersion == 2)

        let fields = d.items.filter { $0.category == .field }
        #expect(fields.count == 1)
        #expect(fields.first?.change == .added)
        #expect(fields.first?.subject == "本の種別")

        let formats = d.items.filter { $0.category == .filenameFormat }
        #expect(formats.count == 1)
        #expect(formats.first?.change == .added)
        #expect(formats.first?.subject == "(@booktype) [@author] @title")
        // **並べ替えは出ない**——共通の 2 本の相対順は変わっていない。
        #expect(!d.items.contains { $0.category == .filenameFormatOrder })
    }

    /// **プリセットが持たない項目は差分に出ない。** 対象拡張子・保護文字列・
    /// 区切りは `draft(from:)` が両側に同じ既定値を入れるため、除外リストを
    /// 書かなくても構造的に外れる。
    @Test func doesNotSurfaceSettingsThePresetDoesNotCarry() {
        var current = Self.currentDraft()
        current.targetExtensions = ["cbz"]
        current.protectedTokens = []
        current.seriesTitleCompositionFormat = "@series"
        let d = Self.diff(current: current)
        #expect(d.items.allSatisfy { $0.category != .field || $0.change == .added })
        #expect(d.items.count == 2)   // フィールド 1 ＋ フォーマット 1
    }

    /// 利用者が既にそのフォーマットを自分で足していれば出さない。
    @Test func skipsWhatTheUserAlreadyAdded() {
        var current = Self.currentDraft()
        current.filenameFormats.insert(
            FilenameFormatDraft(source: "(@booktype) [@author] @title"), at: 0)
        let d = Self.diff(current: current)
        #expect(!d.items.contains { $0.category == .filenameFormat })
    }

    /// 利用者が自分で消したフォーマットは「追加」として蘇らない
    /// ——base があるからこそ区別できる [LT-15]。
    @Test func doesNotResurrectWhatTheUserDeleted() {
        var current = Self.currentDraft()
        current.filenameFormats.removeAll { $0.source == "@title" }
        let d = Self.diff(current: current)
        #expect(!d.items.contains { $0.subject == "@title" })
    }

    /// プリセットが消したフォーマットは、ライブラリにまだ在るときだけ出す。
    @Test func surfacesRemovalOnlyWhenStillPresent() {
        let shrunk = Self.template(
            version: 2,
            fields: [Self.field(1, "著者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["[@author] @title"])
        let present = Self.diff(current: Self.currentDraft(), latest: shrunk)
        #expect(present.items.contains { $0.change == .removed && $0.subject == "@title" })

        var without = Self.currentDraft()
        without.filenameFormats.removeAll { $0.source == "@title" }
        let absent = Self.diff(current: without, latest: shrunk)
        #expect(!absent.items.contains { $0.change == .removed })
    }

    // MARK: - ローカル編集 [LT-15]

    @Test func marksLocallyEditedFieldNames() {
        let renamed = Self.template(
            version: 2,
            fields: [Self.field(1, "作者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["[@author] @title", "@title"])
        var current = Self.currentDraft()
        current.fields[0].name = "わたしの著者"

        let d = Self.diff(current: current, latest: renamed)
        let item = d.items.first { $0.category == .field && $0.change == .modified }
        #expect(item?.isLocallyEdited == true)
        #expect(item?.previous == "わたしの著者")
        // **ローカル編集済みは既定で選ばれない** [LT-14][LT-15]。
        #expect(item?.isSelected == false)
    }

    /// 利用者が触っていない項目は既定で選ばれる。
    @Test func selectsUntouchedItemsByDefault() {
        let d = Self.diff(current: Self.currentDraft())
        #expect(d.items.allSatisfy { $0.isSelected })
        #expect(d.selected.count == d.items.count)
    }

    // MARK: - 並べ替え [FF-03]

    @Test func surfacesReorderOfSharedFormats() {
        let reordered = Self.template(
            version: 2,
            fields: [Self.field(1, "著者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["@title", "[@author] @title"])
        let d = Self.diff(current: Self.currentDraft(), latest: reordered)
        let item = d.items.first { $0.category == .filenameFormatOrder }
        #expect(item?.change == .reordered)
        #expect(item?.action == .reorderFilenameFormats(order: ["@title", "[@author] @title"]))
    }

    // MARK: - 適用 [LT-14]

    @Test func appliesOnlySelectedItems() {
        let d = Self.diff(current: Self.currentDraft())
        let onlyField = d.items.filter { $0.category == .field }
        let applied = TemplateDiff.applying(onlyField, to: Self.currentDraft())

        #expect(applied.fields.contains { $0.index == 7 && $0.name == "本の種別" })
        #expect(applied.semanticBindings[.bookType] == 7)
        // フォーマットは選んでいないので増えない。
        #expect(applied.filenameFormats.count == 2)
    }

    /// 追加したフォーマットは**プリセット上の位置**へ入る [FF-03]。
    @Test func insertsAddedFormatAtThePresetPosition() {
        let d = Self.diff(current: Self.currentDraft())
        let applied = TemplateDiff.applying(d.items, to: Self.currentDraft())
        #expect(applied.filenameFormats.map(\.source)
            == ["(@booktype) [@author] @title", "[@author] @title", "@title"])
    }

    /// **利用者が足したフォーマットを落とさない** [D3]。
    @Test func keepsUserAddedFormatsWhenReordering() {
        let reordered = Self.template(
            version: 2,
            fields: [Self.field(1, "著者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["@title", "[@author] @title"])
        var current = Self.currentDraft()
        current.filenameFormats.append(FilenameFormatDraft(source: "わたしの形式 @title"))

        let d = Self.diff(current: current, latest: reordered)
        let applied = TemplateDiff.applying(d.items, to: current)
        #expect(applied.filenameFormats.map(\.source)
            == ["@title", "[@author] @title", "わたしの形式 @title"])
    }

    /// 追加するフィールドの番号が埋まっていたら空き番号へ置き、
    /// **束縛もその番号へ向ける** [Stage 5: 番号は身元ではない]。
    @Test func placesAddedFieldOnAFreeIndex() {
        var current = Self.currentDraft()
        current.fields.append(FieldDraft(index: 7, name: "わたしの軸",
                                         colorHexLight: "#111111", colorHexDark: "#EEEEEE"))
        let d = Self.diff(current: current)
        let applied = TemplateDiff.applying(d.items, to: current)

        #expect(applied.fields.contains { $0.index == 7 && $0.name == "わたしの軸" })
        let added = applied.fields.first { $0.name == "本の種別" }
        #expect(added != nil)
        #expect(added?.index != 7)
        #expect(applied.semanticBindings[.bookType] == added?.index)
    }

    /// 既に同じ意味のフィールドを持っているなら、追加を出さない
    /// ——名前が違っても**束縛が同じなら同じ軸**である。
    @Test func skipsFieldAdditionWhenTheKeywordIsAlreadyBound() {
        var current = Self.currentDraft()
        current.fields.append(FieldDraft(index: 9, name: "種別",
                                         colorHexLight: "#111111", colorHexDark: "#EEEEEE"))
        current.semanticBindings[.bookType] = 9
        let d = Self.diff(current: current)
        #expect(!d.items.contains { $0.category == .field })
    }

    /// **フィールドの削除は差分に出さない**——`updateSettings` が
    /// ラベルごと連鎖削除し、⌘Z で戻らないため [LT-16 を満たせない]。
    @Test func neverSurfacesFieldRemoval() {
        let shrunk = Self.template(
            version: 2,
            fields: [Self.field(1, "著者")],
            bindings: ["@author": 1],
            formats: ["[@author] @title", "@title"])
        let d = Self.diff(current: Self.currentDraft(), latest: shrunk)
        #expect(!d.items.contains { $0.category == .field })
    }

    /// **フィールドの上限が埋まっていたら追加を出さない** [AL-05]。
    ///
    /// 出すと草案の検証が通らず、`updateSettings` が投げて**同時に選んだ
    /// 他の項目まで巻き添えで適用されない**——しかも base が進まないので
    /// 案内が永久に消えない［code-review の指摘］。
    @Test func skipsFieldAdditionWhenAllIndexesAreTaken() {
        var current = Self.currentDraft()
        for index in 4...AppLimits.Format.maxFields {
            current.fields.append(FieldDraft(index: index, name: "軸\(index)",
                                             colorHexLight: "#111111", colorHexDark: "#EEEEEE"))
        }
        #expect(current.fields.count == AppLimits.Format.maxFields)

        let d = Self.diff(current: current)
        #expect(!d.items.contains { $0.category == .field })
        // 他の項目は巻き添えにならない。
        #expect(d.items.contains { $0.category == .filenameFormat })
    }

    /// **利用者が並べ替えただけでは差分に出ない。**
    ///
    /// プリセットの変更として提示すると、チェックした利用者の優先順が
    /// 巻き戻る［code-review の指摘。フィールド名と階層割り当ては同じ
    /// ガードを持っていたので、ここだけ抜けていた］。
    @Test func doesNotSurfaceAReorderTheUserMadeThemselves() {
        var current = Self.currentDraft()
        current.filenameFormats.reverse()
        // プリセット側は並びを変えていない（`latest` は base の並びを保つ）。
        let d = Self.diff(current: current)
        #expect(!d.items.contains { $0.category == .filenameFormatOrder })
    }

    // MARK: - 巻数フォーマット

    @Test func surfacesAddedVolumePattern() {
        let widened = Self.template(
            version: 2,
            fields: [Self.field(1, "著者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["[@author] @title", "@title"],
            volumeSet: "VS2")
        let d = Self.diff(current: Self.currentDraft(), latest: widened)
        let item = d.items.first { $0.category == .volumeFormat }
        #expect(item?.change == .added)

        let applied = TemplateDiff.applying(d.items, to: Self.currentDraft())
        #expect(applied.volumeFormats.count == 2)
    }

    // MARK: - フォルダ階層

    @Test func surfacesFolderLevelChange() {
        let foldered = Self.template(
            version: 2,
            fields: [Self.field(1, "著者"), Self.field(2, "サークル"), Self.field(3, "ジャンル")],
            bindings: ["@author": 1, "@circle": 2, "@genre": 3],
            formats: ["[@author] @title", "@title"],
            folderLevels: ["1": .init(kind: .singleLabelGroup, labelGroup: 1, format: nil)])
        let d = Self.diff(current: Self.currentDraft(), latest: foldered)
        let item = d.items.first { $0.category == .folderLevel }
        #expect(item?.change == .added)

        let applied = TemplateDiff.applying(d.items, to: Self.currentDraft())
        #expect(applied.folderLevels.first?.assignment == .singleLabelGroup(index: 1))
    }

    // MARK: - 何も変わっていないとき

    @Test func producesNothingWhenThePresetDidNotChange() {
        let d = Self.diff(current: Self.currentDraft(), latest: Self.base)
        #expect(d.isEmpty)
    }
}
