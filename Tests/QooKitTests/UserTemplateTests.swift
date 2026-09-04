//
//  ユーザー定義テンプレート [LT-02][LT-05][LT-06]。
//
import Foundation
import Testing

@testable import QooKit

@Suite struct UserTemplateTests {

    /// 既定値と区別できるよう、**すべての設定を既定でない値**にした草案。
    ///
    /// 既定のままの項目があると、写し漏れがあっても両側が同じ既定値になって
    /// **テストが通ってしまう**（`BackupTests` で実際に踏んだ空振りと同じ形）。
    static func fullyPopulatedDraft() -> LibrarySettingsDraft {
        LibrarySettingsDraft(
            displayName: "表示名",
            thumbnailsAlwaysHidden: true,
            duplicateGrouping: .byTitleAndVolume,
            targetExtensions: ["cbz", "zip"],
            imageExtensions: ["png", "jpg"],
            delimiters: DelimiterSet(
                pairs: [PairDelimiter(open: "【", close: "】")],
                separators: [SeparatorDelimiter(canonical: "_", isEnabled: true)]),
            protectedTokens: [
                ProtectedToken(pattern: #"\(完結\)"#, position: .suffix, isEnabled: false)
            ],
            fields: [
                FieldDraft(index: 1, name: "著者", colorHexLight: "#111111",
                           colorHexDark: "#222222", assignsAutomatically: false),
                FieldDraft(index: 2, name: "サークル", colorHexLight: "#333333",
                           colorHexDark: "#444444", assignsAutomatically: true),
            ],
            semanticBindings: [.author: 1, .circle: 2],
            filenameFormats: [
                FilenameFormatDraft(source: "[@author] @title", isEnabled: true),
                FilenameFormatDraft(source: "@title", isEnabled: false),
            ],
            volumeFormats: [
                VolumeFormatDraft(source: #"第(\d+)巻"#, isEnabled: true, kind: .volume),
                VolumeFormatDraft(source: "上巻", isEnabled: false, kind: .separator),
            ],
            folderLevels: [
                FolderLevelDraft(level: 1, assignment: .singleLabelGroup(index: 2)),
                FolderLevelDraft(level: 2, assignment: .format(source: "[@author]")),
                FolderLevelDraft(level: 3, assignment: FolderLevelDraft.Assignment.none),
            ],
            seriesTitleCompositionFormat: "@series 第@volume巻",
            readsEmbeddedMetadata: false,
            comicInfoVolumeSource: .number,
            opensBookFolderWithApp: true,
            bookTypeVocabulary: ["ほかのタイプ"])
    }

    static func settingsKeys() throws -> Set<String> {
        let data = try JSONEncoder().encode(UserTemplateSettings(fullyPopulatedDraft()))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - 網羅性

    /// **草案へ設定を足したら、テンプレートにも足すこと。**
    ///
    /// 落とすと「保存して読み直した瞬間に別物になる」——それがユーザー定義
    /// テンプレートで最も避けたい壊れ方（`UserTemplate.swift` の解説）。
    /// この検査は**プロパティを列挙しない**ので、草案が増えれば自動的に広がる。
    @Test func documentCoversEveryDraftField() throws {
        // 意図的に持たないもの。**理由は `UserTemplateSettings` の表にある。**
        // ここへ足すときは、なぜ持たなくてよいかを併せて書くこと。
        let intentionallyExcluded: Set<String> = ["displayName", "bookTypeVocabulary"]
        let keys = try Self.settingsKeys()
        let mirror = Mirror(reflecting: Self.fullyPopulatedDraft())
        var checked = 0
        for child in mirror.children {
            guard let name = child.label else { continue }
            checked += 1
            #expect(intentionallyExcluded.contains(name) || keys.contains(name),
                    "草案の設定 '\(name)' がテンプレートに無い。UserTemplateSettings へ足すか、意図的な除外なら理由付きで除外リストへ")
        }
        // 検査そのものが空振りしていないことの担保。
        #expect(checked >= 16)
    }

    // MARK: - 往復

    /// **鍵を足したのに `init(from:)` へ書き忘れた**を捕まえる。
    ///
    /// 合成された `CodingKeys` は鍵を増やすが、手書きの `init(from:)` に
    /// 1 行足し忘れても**コンパイラは何も言わず、読まれないまま既定値に落ちる**
    /// （`LibrarySettingsPayload` で実際に踏んだ）。1 つでも読まれなければ
    /// 再符号化が既定値へ戻って食い違う。
    @Test func everyFieldSurvivesARoundTrip() throws {
        let original = UserTemplateSettings(Self.fullyPopulatedDraft())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(UserTemplateSettings.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(first == second)
        #expect(decoded == original)
    }

    /// 草案 → テンプレート → 草案で、設定が 1 つも変わらない。
    ///
    /// `id` は揮発値なので比べない（比べると必ず落ちる）。
    @Test func draftRoundTripPreservesEverySetting() {
        let original = Self.fullyPopulatedDraft()
        let restored = UserTemplateSettings(original)
            .draft(displayName: original.displayName,
                   bookTypeVocabulary: original.bookTypeVocabulary)

        #expect(restored.thumbnailsAlwaysHidden == original.thumbnailsAlwaysHidden)
        #expect(restored.duplicateGrouping == original.duplicateGrouping)
        #expect(restored.targetExtensions == original.targetExtensions)
        #expect(restored.imageExtensions == original.imageExtensions)
        #expect(restored.delimiters == original.delimiters)
        #expect(restored.protectedTokens.map(\.pattern) == original.protectedTokens.map(\.pattern))
        #expect(restored.protectedTokens.map(\.position)
                == original.protectedTokens.map(\.position))
        #expect(restored.protectedTokens.map(\.isEnabled)
                == original.protectedTokens.map(\.isEnabled))
        #expect(restored.fields.map(\.index) == original.fields.map(\.index))
        #expect(restored.fields.map(\.name) == original.fields.map(\.name))
        #expect(restored.fields.map(\.colorHexLight) == original.fields.map(\.colorHexLight))
        #expect(restored.fields.map(\.colorHexDark) == original.fields.map(\.colorHexDark))
        #expect(restored.fields.map(\.assignsAutomatically)
                == original.fields.map(\.assignsAutomatically))
        #expect(restored.semanticBindings == original.semanticBindings)
        #expect(restored.filenameFormats.map(\.source) == original.filenameFormats.map(\.source))
        #expect(restored.filenameFormats.map(\.isEnabled)
                == original.filenameFormats.map(\.isEnabled))
        #expect(restored.volumeFormats.map(\.source) == original.volumeFormats.map(\.source))
        #expect(restored.volumeFormats.map(\.isEnabled)
                == original.volumeFormats.map(\.isEnabled))
        #expect(restored.volumeFormats.map(\.kind) == original.volumeFormats.map(\.kind))
        #expect(restored.folderLevels.map(\.level) == original.folderLevels.map(\.level))
        #expect(restored.folderLevels.map(\.assignment)
                == original.folderLevels.map(\.assignment))
        #expect(restored.seriesTitleCompositionFormat == original.seriesTitleCompositionFormat)
        #expect(restored.readsEmbeddedMetadata == original.readsEmbeddedMetadata)
        #expect(restored.comicInfoVolumeSource == original.comicInfoVolumeSource)
        #expect(restored.opensBookFolderWithApp == original.opensBookFolderWithApp)
        #expect(restored.bookTypeVocabulary == original.bookTypeVocabulary)
    }

    /// **「明示的に割り当てない」[AL-03] が消えない。**
    ///
    /// 素の `.none` は Swift が `Optional.none` と解釈する——このコードベースで
    /// 4 度踏んでいる罠なので、往復で残ることを直に固定する。
    @Test func explicitlyUnassignedLevelSurvives() {
        let draft = LibrarySettingsDraft(
            folderLevels: [FolderLevelDraft(level: 2,
                                            assignment: FolderLevelDraft.Assignment.none)])
        let restored = UserTemplateSettings(draft).draft(displayName: "x")
        #expect(restored.folderLevels.count == 1)
        #expect(restored.folderLevels.first?.assignment == FolderLevelDraft.Assignment.none)
    }

    // MARK: - 古い文書・壊れた文書

    /// 鍵が欠けていても読める（古いアプリが書いた文書）。
    @Test func decodesDocumentMissingEveryOptionalKey() throws {
        let json = Data(#"{"templates":[{"name":"最小"}]}"#.utf8)
        let document = try JSONDecoder().decode(UserTemplateDocument.self, from: json)
        #expect(document.schemaVersion == 1)
        #expect(document.templates.count == 1)
        #expect(document.templates[0].name == "最小")
        #expect(document.templates[0].version == 1)
        #expect(document.templates[0].settings.filenameFormats.isEmpty)
    }

    /// 撤去された予約語を含む古い文書は、その束縛だけが落ちる [§19.8]。
    @Test func unknownReservedWordsAreDropped() throws {
        var settings = UserTemplateSettings()
        settings.semanticBindings = ["@author": 1, "@labelgroup2": 2, "@libraryname": 3]
        let draft = settings.draft(displayName: "x")
        #expect(draft.semanticBindings == [.author: 1])
    }

    /// **新しすぎる版は読まない** [F21]。
    @Test func rejectsDocumentsFromANewerApp() {
        let newer = UserTemplateDocument(schemaVersion: UserTemplateDocument
            .currentSchemaVersion + 1, templates: [])
        #expect(!newer.isReadable)
        #expect(UserTemplateDocument(templates: []).isReadable)
    }

    // MARK: - 保存の仕方

    /// 別名で保存は**新しい身元**を振る（＝プリセットも元のテンプレートも無傷）。
    @Test func savingAsMakesANewIdentity() {
        let original = UserTemplate(name: "元", settings: UserTemplateSettings())
        var edited = UserTemplateSettings()
        edited.seriesTitleCompositionFormat = "変えた"
        let copy = original.savedAs(name: "別名", settings: edited)
        #expect(copy.id != original.id)
        #expect(copy.name == "別名")
        #expect(copy.version == 1)
        #expect(copy.settings.seriesTitleCompositionFormat == "変えた")
        #expect(original.settings.seriesTitleCompositionFormat == "@series @volume")
    }

    /// 上書き保存は身元を保ち、版を 1 つ進める。
    @Test func updatingKeepsTheIdentityAndAdvancesTheVersion() {
        let now = Date(timeIntervalSince1970: 1_000)
        let original = UserTemplate(name: "元", createdAt: now, updatedAt: now,
                                    settings: UserTemplateSettings())
        let later = Date(timeIntervalSince1970: 2_000)
        let updated = original.updated(settings: UserTemplateSettings(), now: later)
        #expect(updated.id == original.id)
        #expect(updated.version == original.version + 1)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.updatedAt == later)
    }

    /// 同名を許す（名前は身元ではない）[LT-02]。
    @Test func namesMayCollide() {
        let a = UserTemplate(name: "同じ名前", settings: UserTemplateSettings())
        let b = UserTemplate(name: "同じ名前", settings: UserTemplateSettings())
        #expect(a.id != b.id)
    }
}

@Suite struct SettingsValidationContextTests {

    /// **テンプレートは表示名を持たない** [RG3-31][LT-02]。
    ///
    /// 要求すると、テンプレート管理ウインドウで消しようのない不備が出て
    /// 保存が永久に無効になる（表示名の欄は §19.10 ステージ 7 で撤去済み）。
    @Test func templatesDoNotRequireADisplayName() {
        var draft = LibrarySettingsDraft(
            displayName: "",
            targetExtensions: ["cbz"],
            filenameFormats: [FilenameFormatDraft(source: "@title", isEnabled: true)])
        draft.fields = []

        let asLibrary = draft.validate(as: .library).filter { $0.severity == .error }
        let asTemplate = draft.validate(as: .template).filter { $0.severity == .error }

        #expect(asLibrary.contains { $0.message.contains("表示名") })
        #expect(!asTemplate.contains { $0.message.contains("表示名") })
        #expect(asTemplate.isEmpty, "表示名以外に不備が無ければテンプレートとして保存できる")
    }

    /// **白紙から作った草案は、そのままテンプレートとして保存できる。**
    ///
    /// 以前はブックタイプ名が必須だったため、テンプレートマネージャの ＋ が
    /// 「このテンプレートはまだ保存できません」で必ず弾かれ、白紙から作る道が
    /// 塞がっていた［実機検証で発見、2026-09-04］。本の種別をライブラリ固有の
    /// 設定から外した [TY-01] ことで、原因ごと消えた。
    @Test func aBlankDraftCanBeSavedAsATemplate() throws {
        let sets = try BuiltInTemplates.volumeSets()
        let blank = TemplateInstantiation.blankDraft(
            volumeSets: sets, displayName: "白紙",
            defaultFieldNames: ["著者", "サークル", "ジャンル", "イベント", "キーワード", "本の種別"])
        #expect(blank.validate(as: .template).filter { $0.severity == .error }.isEmpty)
    }

    /// 表示名以外の不備は**どちらの文脈でも**止める [H1]。
    @Test func otherProblemsStillBlockTemplates() {
        let draft = LibrarySettingsDraft(displayName: "",
                                         targetExtensions: [])
        let asTemplate = draft.validate(as: .template).filter { $0.severity == .error }
        #expect(asTemplate.contains { $0.message.contains("対象拡張子") })
    }
}
