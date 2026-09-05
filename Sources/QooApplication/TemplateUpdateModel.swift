//
//  プリセット改訂の検出と差分ビュー [LT-10〜LT-17][12章 TU-01〜TU-06]。
//
//  ## 対象は「プリセット由来で、登録時の定義を持つ」ライブラリだけ
//  ユーザー定義テンプレート・白紙からの登録は `registeredTemplateJSON` を
//  持たない（`register` がプリセットのときだけ書く）ので、構造的に外れる
//  ——「改訂」という概念がそもそも無いものに差分を出さない。
//
//  ## 自動反映しない [LT-11]
//  検出しても設定には一切触れない。触るのは利用者が差分ビューで選んで
//  「適用」を押したときだけで、それが `ApplyTemplateDiffCommand` になる。
//
import Foundation
import QooInfrastructure
import QooKit

@MainActor
@Observable
public final class TemplateUpdateModel {

    /// 改訂が見つかったライブラリ 1 件 [LT-10][LT-12]。
    public struct Pending: Sendable, Hashable, Identifiable {
        public let libraryID: LibraryID
        public let libraryUUID: UUID
        public let libraryName: String
        public let presetKey: String
        public let presetName: String
        public let fromVersion: Int
        public let toVersion: Int
        public var id: LibraryID { libraryID }
    }

    /// 差分ビューが出せない理由 [ER-03]。**「何も無い」と「出せない」を
    /// 区別する**——同じ空の画面にすると、対象外なのか最新なのかが読めない。
    public enum Unavailable: Sendable, Hashable {
        /// 登録時の定義を持たない（ユーザー定義・白紙・v17 より前の登録）。
        case noBase
        /// プリセットが見つからない（アプリからそのプリセットが消えた）。
        case presetMissing
        /// 既に最新。
        case upToDate
    }

    public enum State: Sendable, Equatable {
        case idle
        case loading
        case ready
        case unavailable(Unavailable)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var diff: TemplateDiff?
    /// 差分を作った時点の最新プリセット。適用で base をここへ進める [LT-16]。
    public private(set) var advancedBase: LibraryTypeTemplate?
    public private(set) var libraryName: String = ""

    public init() {}

    // MARK: - 検出 [LT-10][LT-12]

    /// 改訂のあるライブラリを列挙する。**設定には一切触れない** [LT-11]。
    ///
    /// 版が**下がっている**場合は報告しない——アプリを古い版へ戻した状況で、
    /// 「更新されました」と言うのは嘘になる。
    public static func pending(services: LibraryServices) async -> [Pending] {
        var out: [Pending] = []
        for library in services.libraries {
            guard let base = try? await services.registeredTemplate(libraryID: library.id),
                  let latest = services.presetTemplate(key: base.key),
                  latest.version > base.version
            else { continue }
            out.append(Pending(libraryID: library.id, libraryUUID: library.uuid,
                               libraryName: library.displayName,
                               presetKey: base.key, presetName: latest.displayName,
                               fromVersion: base.version, toVersion: latest.version))
        }
        return out
    }

    // MARK: - 差分 [LT-13]

    public func load(libraryID: LibraryID, services: LibraryServices) async {
        state = .loading
        diff = nil
        advancedBase = nil
        libraryName = services.libraries.first { $0.id == libraryID }?.displayName ?? ""
        do {
            guard let base = try await services.registeredTemplate(libraryID: libraryID) else {
                state = .unavailable(.noBase); return
            }
            guard let latest = services.presetTemplate(key: base.key) else {
                state = .unavailable(.presetMissing); return
            }
            guard latest.version > base.version else {
                state = .unavailable(.upToDate); return
            }
            guard let current = try await services.settingsDraft(libraryID: libraryID) else {
                state = .failed(TemplateUpdateError.settingsUnavailable.localizedDescription)
                return
            }
            diff = TemplateDiffBuilder.diff(
                base: base, latest: latest, current: current,
                volumeSets: services.volumeSetDefinition ?? .empty)
            advancedBase = latest
            state = .ready
        } catch {
            // 取り消しは失敗ではない [1-16b の教訓]——次の読み込みが上書きする。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// 項目の選択を切り替える [LT-14]。
    public func setSelected(_ itemID: UUID, _ selected: Bool) {
        guard var diff else { return }
        guard let index = diff.items.firstIndex(where: { $0.id == itemID }) else { return }
        diff.items[index].isSelected = selected
        self.diff = diff
    }

    public var selectedCount: Int { diff?.selected.count ?? 0 }

    /// **ローカル編集を上書きする項目を選んでいるか** [LT-15]。
    /// 画面はこれを見て警告を出す。
    public var overwritesLocalEdits: Bool {
        diff?.selected.contains(where: \.isLocallyEdited) ?? false
    }

    // MARK: - 適用 [LT-14][LT-16]

    /// 選んだ項目を適用し、base を最新へ進める。
    ///
    /// **1 件も選ばずに呼べる**——その場合は設定を変えずに「この改訂は
    /// 判断済み」にするだけ [LT-16]。見送る手段が無いと、適用したくない
    /// 改訂の通知が永久に消えない。
    ///
    /// - Returns: 設定が実際に変わったか（＝再適用を促すべきか [AT-04]）。
    @discardableResult
    public func apply(libraryID: LibraryID, services: LibraryServices,
                      stack: CommandStack) async throws -> Bool
    {
        guard let diff, let advancedBase else { return false }
        let selected = diff.selected
        let command = ApplyTemplateDiffCommand(
            libraryID: libraryID, libraryName: libraryName,
            items: selected, advancedBase: advancedBase, services: services)
        try await stack.run(command)
        state = .unavailable(.upToDate)
        self.diff = nil
        return !selected.isEmpty
    }
}
