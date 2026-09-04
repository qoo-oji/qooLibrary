//
//  ライブラリ有効化画面の状態 [LT-01〜LT-03][LS-01][HP-05、ユーザー要望]。
//
//  **テンプレートを選ぶだけでは「何がどう変わるか」が分からない**という指摘への
//  答え。ここが持つのは ①どのテンプレートを起点にするか ②編集中の草案
//  ③その草案を実ファイル名へ当てた結果、の 3 つ。
//
//  設定ウインドウ（`LibrarySettingsModel`）との違いは**DB 上のライブラリを
//  前提にしないこと**だけで、編集する型（`LibrarySettingsDraft`）も
//  エディタ View も同じものを使う——同じ編集 UI を 2 つ作らない。
//
import Observation
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

@MainActor
@Observable
final class LibraryEnableModel {

    /// 起点の選択。プリセットか、ユーザー定義か、白紙か [LT-02]。
    enum Origin: Hashable, Identifiable {
        case template(key: String)
        /// ユーザー定義テンプレート [LT-02]。プリセットと**同じ扱い**で、
        /// 違うのは草案の作り方だけ（あちらは `draft(from:)`、こちらは
        /// 保存された設定をそのまま草案へ戻す）。
        case userTemplate(id: UUID)
        case blank
        var id: String {
            switch self {
            case .template(let key): key
            case .userTemplate(let id): "user.\(id.uuidString)"
            case .blank: "__blank__"
            }
        }
    }

    let folderName: String
    let folderURL: URL
    let templates: [LibraryTypeTemplate]
    /// ユーザー定義テンプレート [LT-02]。プリセットと同じ一覧に並ぶ。
    let userTemplates: [UserTemplate]
    private let volumeSets: VolumeSetDefinition
    private let bookTypeVocabulary: [String]

    var origin: Origin {
        didSet {
            guard origin != oldValue else { return }
            // **起点を変えたら草案を作り直す。** 編集内容は捨てる——
            // 別のテンプレートへ移るのは「やり直す」という意思表示なので、
            // 混ぜると何を基にしているのか分からなくなる。
            rebuildDraft()
        }
    }
    var draft: LibrarySettingsDraft
    var section: LibrarySettingsSection = .basics

    /// フォーマット一覧で選択中の行。
    var selectedFormatID: UUID?
    /// フォーマット編集のサンプル入力 [HP-05]。
    var sampleFilename: String = ""

    /// 走査対象になるファイル名（実フォルダから読む）。
    private(set) var sampleNames: [String] = []
    private(set) var sampleTruncated = false
    /// サブフォルダの中にあったファイル数 [RG3-24]。
    private(set) var sampleNestedCount = 0
    /// 拡張子（小文字）ごとの件数。ウィザードの「本を開くアプリ」が
    /// 「このフォルダに実際に含まれる形式」だけを並べるのに使う。
    private(set) var sampleExtensionCounts: [String: Int] = [:]
    private(set) var isSampling = true
    private(set) var samplingFailure: String?

    /// プレビューの結果。草案とサンプルから**その場で**計算する。
    var preview: LibraryPreview.Outcome {
        LibraryPreview.run(filenames: sampleNames, draft: draft, truncated: sampleTruncated)
    }

    var issues: [LibrarySettingsIssue] { draft.validate() }
    var errors: [LibrarySettingsIssue] { issues.filter { $0.severity == .error } }
    var canEnable: Bool { errors.isEmpty && !folderName.isEmpty }

    /// 登録時に**プリセットの行を共有してよい**テンプレート [LT-05]。
    ///
    /// **ユーザー定義では `nil` を返す。** 返すとリポジトリがプリセット行
    /// （`presetKey` 付き・`isPreset=1`）を作ってしまい、他のライブラリと
    /// 型名を共有してしまう。ユーザー定義は専用の非プリセット型になるのが正しい。
    var selectedTemplate: LibraryTypeTemplate? {
        guard case .template(let key) = origin else { return nil }
        return templates.first { $0.key == key }
    }

    var selectedUserTemplate: UserTemplate? {
        guard case .userTemplate(let id) = origin else { return nil }
        return userTemplates.first { $0.id == id }
    }

    init(folderName: String, folderURL: URL, templates: [LibraryTypeTemplate],
         volumeSets: VolumeSetDefinition,
         userTemplates: [UserTemplate] = [],
         bookTypeVocabulary: [String] = []) {
        self.folderName = folderName
        self.folderURL = folderURL
        self.templates = templates
        self.userTemplates = userTemplates
        self.volumeSets = volumeSets
        self.bookTypeVocabulary = bookTypeVocabulary
        let first = templates.first
        self.origin = first.map { Origin.template(key: $0.key) } ?? .blank
        self.draft = first.map {
            TemplateInstantiation.draft(from: $0, volumeSets: volumeSets,
                                        displayName: folderName,
                                        bookTypeVocabulary: bookTypeVocabulary)
        } ?? TemplateInstantiation.blankDraft(
            volumeSets: volumeSets, displayName: folderName,
            defaultFieldNames: DefaultFieldNames.localized,
            bookTypeVocabulary: bookTypeVocabulary)
        self.selectedFormatID = draft.filenameFormats.first?.id
    }

    /// 起点から草案を作り直す。
    func rebuildDraft() {
        switch origin {
        case .template(let key):
            guard let template = templates.first(where: { $0.key == key }) else { return }
            draft = TemplateInstantiation.draft(
                from: template, volumeSets: volumeSets, displayName: folderName,
                bookTypeVocabulary: bookTypeVocabulary)
        case .userTemplate(let id):
            guard let template = userTemplates.first(where: { $0.id == id }) else { return }
            // **保存された設定をそのまま草案へ戻す。** プリセットと違い
            // 既定値の補完は要らない——保存した時点で全項目が入っている。
            draft = template.settings.draft(displayName: folderName,
                                            bookTypeVocabulary: bookTypeVocabulary)
        case .blank:
            draft = TemplateInstantiation.blankDraft(
                volumeSets: volumeSets, displayName: folderName,
                defaultFieldNames: DefaultFieldNames.localized,
                bookTypeVocabulary: bookTypeVocabulary)
        }
        selectedFormatID = draft.filenameFormats.first?.id
    }

    func reveal(_ issue: LibrarySettingsIssue) {
        section = LibrarySettingsSection(issue.section)
    }

    // MARK: - サンプルの収集

    /// フォルダから走査対象になりそうなファイル名を集める。
    ///
    /// **拡張子で絞らない。** 対象拡張子は草案で編集できる設定なので、
    /// ここで絞ると「拡張子を足したのにプレビューが変わらない」ことになる
    /// ——集めるのは名前だけなので、多少余分に持っても害が無い。
    ///
    /// **再帰する。** 実際の走査 [SY-01] はサブフォルダも見るので、直下だけを
    /// 見せると「自分の蔵書がどう解釈されるか」の答えにならない。
    /// ただし上限で打ち切る——数万件を数えるのは、この画面の目的ではない。
    func loadSamples() async {
        isSampling = true
        defer { isSampling = false }
        let url = folderURL
        let limit = AppLimits.Library.previewSampleLimit
        do {
            // ブロッキング I/O は協調プールの外で待つ [NV6-01]。
            let collected = try await FileIO.perform {
                try Self.collectNames(at: url, limit: limit)
            }
            sampleNames = collected.names
            sampleTruncated = collected.truncated
            sampleNestedCount = collected.nested
            sampleExtensionCounts = collected.extensions
            samplingFailure = nil
        } catch {
            sampleNames = []
            sampleTruncated = false
            sampleNestedCount = 0
            sampleExtensionCounts = [:]
            samplingFailure = error.localizedDescription
        }
    }

    /// - Important: `FileIO.perform` の中からのみ呼ぶこと [NV6-01][NV6-02]。
    /// - Returns: `nested` は**サブフォルダの中にあった**ファイルの数。登録
    ///   ウィザードが「フォルダ分けされた蔵書か」を推定するのに使う [RG3-24]。
    nonisolated static func collectNames(at root: URL, limit: Int)
        throws -> (names: [String], truncated: Bool, nested: Int,
                   extensions: [String: Int])
    {
        var names: [String] = []
        var nested = 0
        var extensions: [String: Int] = [:]
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], false, 0, [:])
        }
        for case let url as URL in enumerator {
            if Cancellation.isRequested { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            names.append(url.lastPathComponent)
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty { extensions[ext, default: 0] += 1 }
            if enumerator.level >= 2 { nested += 1 }
            if names.count >= limit {
                return (names, true, nested, extensions)
            }
        }
        return (names, false, nested, extensions)
    }
}
