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

    /// 起点の選択。プリセットか、白紙か [LT-02]。
    enum Origin: Hashable, Identifiable {
        case template(key: String)
        case blank
        var id: String {
            switch self {
            case .template(let key): key
            case .blank: "__blank__"
            }
        }
    }

    let folderName: String
    let folderURL: URL
    let templates: [LibraryTypeTemplate]
    private let volumeSets: VolumeSetDefinition
    private let otherTypeNames: [String]
    private let otherDisplayNames: [String]

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
    private(set) var isSampling = true
    private(set) var samplingFailure: String?

    /// プレビューの結果。草案とサンプルから**その場で**計算する。
    var preview: LibraryPreview.Outcome {
        LibraryPreview.run(filenames: sampleNames, draft: draft, truncated: sampleTruncated)
    }

    var issues: [LibrarySettingsIssue] { draft.validate() }
    var errors: [LibrarySettingsIssue] { issues.filter { $0.severity == .error } }
    var canEnable: Bool { errors.isEmpty && !folderName.isEmpty }

    var selectedTemplate: LibraryTypeTemplate? {
        guard case .template(let key) = origin else { return nil }
        return templates.first { $0.key == key }
    }

    init(folderName: String, folderURL: URL, templates: [LibraryTypeTemplate],
         volumeSets: VolumeSetDefinition,
         otherTypeNames: [String] = [], otherDisplayNames: [String] = []) {
        self.folderName = folderName
        self.folderURL = folderURL
        self.templates = templates
        self.volumeSets = volumeSets
        self.otherTypeNames = otherTypeNames
        self.otherDisplayNames = otherDisplayNames
        let first = templates.first
        self.origin = first.map { Origin.template(key: $0.key) } ?? .blank
        self.draft = first.map {
            TemplateInstantiation.draft(from: $0, volumeSets: volumeSets,
                                        displayName: folderName,
                                        otherLibraryTypeNames: otherTypeNames,
                                        otherLibraryDisplayNames: otherDisplayNames)
        } ?? TemplateInstantiation.blankDraft(
            volumeSets: volumeSets, displayName: folderName,
            defaultLabelGroupName: String(localized: "libraryEnable.defaultLabelGroupName"),
            otherLibraryTypeNames: otherTypeNames,
            otherLibraryDisplayNames: otherDisplayNames)
        self.selectedFormatID = draft.filenameFormats.first?.id
    }

    /// 起点から草案を作り直す。
    func rebuildDraft() {
        switch origin {
        case .template(let key):
            guard let template = templates.first(where: { $0.key == key }) else { return }
            draft = TemplateInstantiation.draft(
                from: template, volumeSets: volumeSets, displayName: folderName,
                otherLibraryTypeNames: otherTypeNames,
                otherLibraryDisplayNames: otherDisplayNames)
        case .blank:
            draft = TemplateInstantiation.blankDraft(
                volumeSets: volumeSets, displayName: folderName,
                defaultLabelGroupName: String(localized: "libraryEnable.defaultLabelGroupName"),
                otherLibraryTypeNames: otherTypeNames,
                otherLibraryDisplayNames: otherDisplayNames)
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
            samplingFailure = nil
        } catch {
            sampleNames = []
            sampleTruncated = false
            samplingFailure = error.localizedDescription
        }
    }

    /// - Important: `FileIO.perform` の中からのみ呼ぶこと [NV6-01][NV6-02]。
    nonisolated static func collectNames(at root: URL, limit: Int)
        throws -> (names: [String], truncated: Bool)
    {
        var names: [String] = []
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], false)
        }
        for case let url as URL in enumerator {
            if Cancellation.isRequested { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            names.append(url.lastPathComponent)
            if names.count >= limit {
                return (names, true)
            }
        }
        return (names, false)
    }
}
