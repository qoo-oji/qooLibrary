//
//  ライブラリ設定ウインドウの状態 [LS-01〜LS-03][15.1 節]。
//
//  **テンプレートは登録時に一度写されるだけの雛形** [LT-03]。ここが、写された
//  設定を実際に調整できる唯一の場所になる。
//
import Observation
import QooApplication
import QooKit
import SwiftUI

/// 設定項目グループ（中央ペインの行）[15.1 節]。
enum LibrarySettingsSection: String, CaseIterable, Identifiable, Hashable {
    case basics, extensions, labelGroups, filenameFormats
    case folderLevels, volumeFormats, delimiters, protectedTokens
    case embeddedMetadata

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .basics:          "librarySettings.section.basics"
        case .extensions:      "librarySettings.section.extensions"
        case .labelGroups:     "librarySettings.section.labelGroups"
        case .filenameFormats: "librarySettings.section.filenameFormats"
        case .folderLevels:    "librarySettings.section.folderLevels"
        case .volumeFormats:   "librarySettings.section.volumeFormats"
        case .delimiters:      "librarySettings.section.delimiters"
        case .protectedTokens: "librarySettings.section.protectedTokens"
        case .embeddedMetadata: "librarySettings.section.embeddedMetadata"
        }
    }

    var systemImage: String {
        switch self {
        case .basics:          "gearshape"
        case .extensions:      "doc.badge.gearshape"
        case .labelGroups:     "tag"
        case .filenameFormats: "textformat.abc"
        case .folderLevels:    "folder.badge.gearshape"
        case .volumeFormats:   "number"
        case .delimiters:      "parentheses"
        case .protectedTokens: "shield"
        case .embeddedMetadata: "doc.text.magnifyingglass"
        }
    }

    /// 検証の不備が指す設定項目へ移動できるようにする。
    init(_ issueSection: LibrarySettingsIssue.Section) {
        switch issueSection {
        case .basics:          self = .basics
        case .extensions:      self = .extensions
        case .delimiters:      self = .delimiters
        case .protectedTokens: self = .protectedTokens
        case .labelGroups:     self = .labelGroups
        case .filenameFormats: self = .filenameFormats
        case .volumeFormats:   self = .volumeFormats
        case .folderLevels:    self = .folderLevels
        }
    }
}

/// ウインドウ 1 枚分の状態。
///
/// ## 保存は明示的にする［設計判断］
/// 入力のたびに書き戻さない。設定変更は既存ファイルへの再適用を促す [LS-02][AT-04]
/// もので、**編集の途中の（一貫していない）状態が保存されると走査が壊れる**
/// ——ラベルグループを消してからフォーマットを直すまでの間など。草案を手元に
/// 持ち、検証を通ったものだけを一度に書く。
@MainActor
@Observable
final class LibrarySettingsModel {

    var selectedLibraryID: LibraryID? {
        didSet {
            guard selectedLibraryID != oldValue else { return }
            Task { await loadDraft() }
        }
    }
    var section: LibrarySettingsSection = .basics
    /// 編集中の草案。読み込み前・ライブラリ未選択なら `nil`。
    var draft: LibrarySettingsDraft?
    /// 最後に保存された状態。`draft` との差が「未保存の変更」。
    private(set) var savedDraft: LibrarySettingsDraft?
    private(set) var isBusy = false
    private(set) var loadFailure: String?

    /// ファイル名フォーマット一覧で選択中の行。
    var selectedFilenameFormatID: UUID?
    /// プレビュー用のサンプル入力 [HP-05]。ライブラリを跨いで保つ（打ち直しの手間を省く）。
    var sampleFilename: String = ""

    var libraries: [LibrarySummary] { LibraryServices.shared.libraries }

    /// 巻数の判断待ち [EM-31]。設定を開いたときと、判断を確定したあとに読み直す。
    private(set) var pendingVolumeDecisions: [VolumeDecisionCandidate] = []

    var isDirty: Bool {
        guard let draft, let savedDraft else { return false }
        return draft != savedDraft
    }

    var issues: [LibrarySettingsIssue] { draft?.validate() ?? [] }
    var errors: [LibrarySettingsIssue] { issues.filter { $0.severity == .error } }
    var warnings: [LibrarySettingsIssue] { issues.filter { $0.severity == .warning } }
    var canSave: Bool { isDirty && errors.isEmpty && !isBusy }

    var selectedLibraryName: String {
        libraries.first { $0.id == selectedLibraryID }?.displayName ?? ""
    }

    // MARK: - 読み書き

    /// 開いたときに 1 度呼ぶ。まだ何も選ばれていなければ先頭を選ぶ。
    func prepare(preferring libraryID: LibraryID?) async {
        await LibraryServices.shared.refreshLibraries()
        syncSelection(preferring: libraryID)
        if draft == nil { await loadDraft() }
    }

    /// 一覧の顔ぶれに選択を合わせる。**読み込みは行わない。**
    ///
    /// [実機検証で発見] このウインドウは macOS の状態復元で**起動と同時に
    /// 開く**ことがあり、そのとき `LibraryServices.bootstrap()` はまだ走って
    /// いない。`prepare` の 1 回きりで決めると、空の一覧を見て「未選択」に
    /// 確定し、あとから一覧が届いても**何も選ばれないまま**になる
    /// （`RegisteredFolderStore` の `ensureLoaded` で踏んだのと同じ形の競合）。
    /// 一覧の変化にも反応させて、遅れて届いた場合に追いつけるようにする。
    func syncSelection(preferring libraryID: LibraryID? = nil) {
        if let libraryID, libraries.contains(where: { $0.id == libraryID }) {
            selectedLibraryID = libraryID
        } else if selectedLibraryID == nil
                    || !libraries.contains(where: { $0.id == selectedLibraryID }) {
            selectedLibraryID = libraries.first?.id
        }
    }

    func loadDraft() async {
        guard let id = selectedLibraryID else {
            draft = nil
            savedDraft = nil
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let loaded = try await LibraryServices.shared.settingsDraft(libraryID: id)
            draft = loaded
            savedDraft = loaded
            selectedFilenameFormatID = loaded?.filenameFormats.first?.id
            loadFailure = nil
            await loadPendingVolumeDecisions()
        } catch {
            draft = nil
            savedDraft = nil
            loadFailure = error.localizedDescription
        }
    }

    /// 保存する。成功したら「再スキャンするか」を呼び出し側へ返す [LS-02][AT-04]。
    @discardableResult
    func save() async -> Bool {
        guard let draft, let id = selectedLibraryID, errors.isEmpty else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await LibraryServices.shared.updateSettings(draft, libraryID: id)
            savedDraft = draft
            return true
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "librarySettings.saveFailed"))
            return false
        }
    }

    func revert() {
        draft = savedDraft
    }

    // MARK: - 巻数の判断 [EM-30〜EM-35]

    func loadPendingVolumeDecisions() async {
        guard let id = selectedLibraryID else {
            pendingVolumeDecisions = []
            return
        }
        // 一覧が取れないこと自体は利用者に伝えない——設定を見に来ただけの人へ
        // 出すには重すぎる。件数が 0 に見えるだけで、判断は次のスキャンでまた出る。
        pendingVolumeDecisions =
            (try? await LibraryServices.shared.filesAwaitingVolumeDecision(libraryID: id)) ?? []
    }

    /// 不備をクリックしたら、その設定項目へ移動する。
    func reveal(_ issue: LibrarySettingsIssue) {
        section = LibrarySettingsSection(issue.section)
    }

    /// 判断のダイアログが閉じたあとに読み直す。
    ///
    /// **草案も読み直す。**「以降すべてに適用」を選ぶと設定そのものが
    /// 書き換わるので、画面のピッカーが古い値のまま残ってはならない。
    func reloadAfterVolumeDecision() async {
        await loadDraft()
    }
}

/// ウインドウの外から「このライブラリの設定を開いてほしい」と伝える受け皿。
///
/// `PreferencesNavigation` と同じ形。`Window(id:)` は同じ id で再度開いても
/// ビューを作り直さないので、初回表示と「既に開いているウインドウが前面に
/// 来ただけ」の両方を拾える必要がある。
@MainActor
@Observable
final class LibrarySettingsNavigation {
    static let shared = LibrarySettingsNavigation()
    var pendingLibraryID: LibraryID?
    private init() {}
}
