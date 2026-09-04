//
//  テンプレート管理ウインドウの状態 [LT-02][LT-05][LT-06]。
//
//  ## プリセットも編集できる。ただし保存は別名だけ［ユーザー判断、2026-09-04］
//  [LT-05] の「編集不可・複製を促す」を、**上書き保存を出さない**ことで実現する。
//  プリセット本体は決して書き換わらないので目的（初期状態への復帰を保証する）は
//  満たしたまま、「まず複製を押す」という前置きの手順が要らない——試しに弄って
//  から決められる。
//
//  ## 編集 UI は設定ウインドウと共有する
//  `LibraryBasicsSettingsView` ほかをそのまま使う。**同じ編集を 2 つ作らない**
//  ——片方だけ直したときに、テンプレートで設定した値が登録すると違う、という
//  最も気づきにくい壊れ方になる。
//
import Observation
import QooApplication
import QooKit
import SwiftUI

@MainActor
@Observable
final class TemplateManagerModel {

    /// 一覧の選択。プリセットは `key`、ユーザー定義は `id`。
    enum Selection: Hashable {
        case preset(key: String)
        case user(id: UUID)
    }

    private(set) var presets: [LibraryTypeTemplate] = []
    private(set) var userTemplates: [UserTemplate] = []
    private(set) var selection: Selection?

    /// 編集中の草案。**選択したものの写し**で、保存するまで元へは戻さない。
    var draft = LibrarySettingsDraft()
    /// 編集中の名前。プリセットでは元の表示名から始まる。
    var name = ""

    var section: LibrarySettingsSection = .basics
    var selectedFilenameFormatID: UUID?
    var sampleFilename: String = ""

    /// 直近の操作の結果（取り込みの件数など）。**黙って終わらせない**ため。
    private(set) var lastOutcome: String?
    private(set) var errorText: String?

    /// 読み込んだ時点の状態。変更の有無の判定に使う。
    private var baselineDraft = LibrarySettingsDraft()
    private var baselineName = ""

    private var bookTypeVocabulary: [String] = []

    // MARK: - 導出

    var isPreset: Bool {
        if case .preset = selection { return true }
        return false
    }

    var hasSelection: Bool { selection != nil }

    var hasUnsavedChanges: Bool {
        hasSelection && (draft != baselineDraft || name != baselineName)
    }

    /// **テンプレートとして検証する** [LT-02]。表示名はライブラリの属性で、
    /// テンプレートは持たない（`ValidationContext` の解説）——`.library` の
    /// まま検証すると「表示名を入力してください。」が消せず、保存が永久に
    /// 無効になる［code-review で発見］。
    var issues: [LibrarySettingsIssue] { draft.validate(as: .template) }
    var errors: [LibrarySettingsIssue] { issues.filter { $0.severity == .error } }

    /// **不備があるテンプレートは保存させない** [H1]。
    ///
    /// 保存できてしまうと、そのテンプレートから登録した瞬間にフォーマットが
    /// 1 本も無いライブラリができる——設定ウインドウ・ウィザードと同じ判断。
    var canSave: Bool { hasSelection && errors.isEmpty && !trimmedName.isEmpty }

    /// 上書き保存はユーザー定義のときだけ [LT-05]。
    var canSaveInPlace: Bool { canSave && !isPreset }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var selectedUserTemplate: UserTemplate? {
        guard case .user(let id) = selection else { return nil }
        return userTemplates.first { $0.id == id }
    }

    // MARK: - 読み込み

    /// 一覧を読み、何も選んでいなければ選ぶ。
    ///
    /// **1 回きりで決めない。** このウインドウは macOS の状態復元で**起動と
    /// 同時に開く**ことがあり、そのとき `LibraryServices.bootstrap()` はまだ
    /// 走っていない——空の一覧を見て確定すると、あとから届いても何も選ばれない
    /// ままになる（設定ウインドウが `syncSelection` で踏んだのと同じ競合）。
    /// ウインドウ側が一覧の変化にも乗せること。
    func prepare() async {
        let services = LibraryServices.shared
        presets = services.presetTemplates
        userTemplates = services.userTemplates
        bookTypeVocabulary = (try? BuiltInTemplates.bookTypes()) ?? []
        syncSelection()
    }

    /// 一覧の顔ぶれに選択を合わせる。**編集中なら触らない。**
    func syncSelection() {
        // 選んでいたものが消えていたら選び直す（削除の直後・読み直しの後）。
        if case .user(let id) = selection, !userTemplates.contains(where: { $0.id == id }) {
            selection = nil
        }
        if case .preset(let key) = selection, !presets.contains(where: { $0.key == key }) {
            selection = nil
        }
        guard selection == nil else { return }
        // **自分のテンプレートを先に選ぶ。** この画面の主目的は自分の
        // テンプレートの手入れで、プリセットは複製の元でしかない。
        if let first = userTemplates.first {
            select(.user(id: first.id))
        } else if let first = presets.first {
            select(.preset(key: first.key))
        }
    }

    func refresh() async {
        userTemplates = LibraryServices.shared.userTemplates
        syncSelection()
    }

    /// 一覧の選択を変える。**編集中の変更は捨てる。**
    ///
    /// 別のテンプレートへ移るのは「やり直す」という意思表示——混ぜると何を
    /// 基にしているのか分からなくなる（`LibraryEnableModel.origin` と同じ判断）。
    func select(_ new: Selection?) {
        selection = new
        lastOutcome = nil
        errorText = nil
        switch new {
        case .preset(let key):
            guard let template = presets.first(where: { $0.key == key }),
                  let volumeSets = LibraryServices.shared.volumeSetDefinition else { return }
            // **プリセットは `draft(from:)` を通す**——既定値の出どころを
            // あの 1 箇所に閉じたままにする。
            draft = TemplateInstantiation.draft(
                from: template, volumeSets: volumeSets, displayName: "",
                bookTypeVocabulary: bookTypeVocabulary)
            name = template.displayName
        case .user(let id):
            guard let template = userTemplates.first(where: { $0.id == id }) else { return }
            draft = template.settings.draft(displayName: "",
                                            bookTypeVocabulary: bookTypeVocabulary)
            name = template.name
        case nil:
            draft = LibrarySettingsDraft()
            name = ""
        }
        baselineDraft = draft
        baselineName = name
        selectedFilenameFormatID = draft.filenameFormats.first?.id
    }

    func reveal(_ issue: LibrarySettingsIssue) {
        section = LibrarySettingsSection(issue.section)
    }

    // MARK: - 保存

    /// 上書き保存（ユーザー定義のみ）[LT-02]。
    func saveInPlace() async {
        guard canSaveInPlace, let existing = selectedUserTemplate else { return }
        let succeeded = await perform {
            let updated = existing.updated(name: trimmedName,
                                           settings: UserTemplateSettings(draft))
            try await LibraryServices.shared.saveUserTemplate(updated)
            return nil
        }
        // **失敗したら「変更なし」に戻さない**［code-review で発見］。
        // 戻すと「保存」が無効になり（`hasUnsavedChanges` で塞いでいる）、
        // 書けなかったのに retry する手段が消える。
        guard succeeded else { return }
        await refresh()
        baselineDraft = draft
        baselineName = name
    }

    // 別名で保存（＝プリセットからの複製 [LT-05] も兼ねる）は
    // `TemplateSaveAction` が担う——設定ウインドウ・ウィザードと**同じ実装**を
    // 共有するため、ここには置かない。

    /// 削除 [★14]。**登録済みのライブラリがあっても消せる**（設定は写し済み）。
    func delete() async {
        guard case .user(let id) = selection else { return }
        let succeeded = await perform {
            try await LibraryServices.shared.removeUserTemplate(id: id)
            return nil
        }
        // **失敗したら選択を動かさない**［code-review で発見］。
        // 動かすと `syncSelection` → `select` が走って `errorText` を消し、
        // 「消えていないのに何も言わない」という最も分かりにくい形になる。
        guard succeeded else { return }
        selection = nil
        userTemplates = LibraryServices.shared.userTemplates
        syncSelection()
    }

    // MARK: - 入出力 [LT-06]

    func exportDocument() async -> UserTemplateDocument? {
        guard case .user(let id) = selection else { return nil }
        return await LibraryServices.shared.userTemplateDocument(ids: [id])
    }

    func exportAll() async -> UserTemplateDocument {
        await LibraryServices.shared.userTemplateDocument()
    }

    /// 取り込む [LT-06]。**何件入って何件を弾いたかを必ず出す**——黙って
    /// 一部だけ入るのが、この種の機能でいちばん報告されている壊れ方。
    func importTemplates(at url: URL, locale: Locale) async {
        await perform {
            let outcome = try await LibraryServices.shared.importUserTemplates(at: url)
            if outcome.rejections.isEmpty {
                return String(format: String(localized: "templates.importedCount",
                                             locale: locale), outcome.added.count)
            }
            return String(format: String(localized: "templates.importedCountWithRejections",
                                         locale: locale),
                          outcome.added.count, outcome.rejections.count)
        }
        await refresh()
    }

    // MARK: - 共通

    /// - Returns: 成功したか。**呼び出し側は必ず見ること**——失敗したのに
    ///   後始末（選択の移動・変更なしへの戻し）を続けると、書けなかった事実が
    ///   画面から消える［code-review で発見］。
    @discardableResult
    private func perform(_ body: () async throws -> String?) async -> Bool {
        errorText = nil
        lastOutcome = nil
        do {
            lastOutcome = try await body()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }
}
