//
//  ファイル全体の保護 [PR-05]。
//
import Foundation
import QooKit

/// 右ペインの「保護」節。単一選択でも複数選択でも同じ形で効く [PR-05]。
///
/// **スコープごとの付け外しはここでは扱わない。** 基本情報は
/// `InspectorTitleSection`、フィールドはラベルの付け外し [PR-03] が担う
/// ——同じ操作に独立した経路を 2 つ作らない。ここが持つのは「ファイル全体」
/// というワンクリックの単位だけ。
@MainActor
@Observable
public final class ProtectionEditorModel {
    public enum State: Sendable, Equatable {
        case notApplicable
        case loading
        case notInLibrary
        case ready(Subject)
        case failed(String)
    }

    public struct Subject: Sendable, Equatable {
        public let fileIDs: [FileID]
        public let urls: [URL]
        public let displayName: String
        /// そのライブラリのフィールド [PR-02]。「全体」はこれが揃った状態。
        public let fields: [FieldID]
        public let scopes: [FileID: Set<ProtectionScope>]

        public init(fileIDs: [FileID], urls: [URL], displayName: String,
                    fields: [FieldID], scopes: [FileID: Set<ProtectionScope>]) {
            self.fileIDs = fileIDs
            self.urls = urls
            self.displayName = displayName
            self.fields = fields
            self.scopes = scopes
        }

        /// 全対象で全スコープが保護されているか。
        public var isFullyProtected: Bool {
            !fileIDs.isEmpty && fileIDs.allSatisfy {
                (scopes[$0] ?? []).coversEverything(fields: fields)
            }
        }

        /// 1 件でも何かが保護されているか（三状態の中間の判定に使う）。
        public var hasAnyProtection: Bool {
            fileIDs.contains { !(scopes[$0] ?? []).isEmpty }
        }

        public var checkState: LabelEditorModel.CheckState {
            if isFullyProtected { return .all }
            return hasAnyProtection ? .some : .none
        }
    }

    public private(set) var state: State = .notApplicable

    private let commands: CommandStack
    private var services: LibraryServices?
    private var library: LibrarySummary?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    public func load(urls: [URL], library: LibrarySummary?,
                     services: LibraryServices) async {
        guard let library else {
            state = .notApplicable
            return
        }
        self.services = services
        self.library = library
        if case .notApplicable = state { state = .loading }
        do {
            let rowsByURL = try await services.fileRows(at: urls, in: library)
            let rows = urls.compactMap { url in rowsByURL[url].map { (url: url, row: $0) } }
            guard !rows.isEmpty else {
                state = .notInLibrary
                return
            }
            let ids = rows.map(\.row.id)
            // **行から読まない。** 渡された行は読み込み時点の写しで、⌘Z や
            // 走査で保護が変わっていても古いまま。
            let scopes = try await services.protectedScopes(ids: ids)
            let fields = try await services.fields(libraryID: library.id).map(\.id)
            state = .ready(Subject(
                fileIDs: ids, urls: rows.map(\.url),
                displayName: LabelEditorModel.displayName(for: rows.map(\.url)),
                fields: fields, scopes: scopes))
        } catch {
            // **取り消しは失敗ではない**（他のモデルと同じ扱い）。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    /// ファイル全体の保護を切り替える [PR-05]。
    ///
    /// **中間状態は「全部保護する」へ倒す**——`MixedStateCheckbox` の巡回
    /// （中間 → オン）と揃える [RP-02 と同じ向き]。
    public func toggleAll() async throws {
        guard case .ready(let subject) = state, let services, let library else { return }
        guard let command = try await SetProtectionCommand.togglingAll(
            files: Array(zip(subject.fileIDs, subject.urls)).map { (id: $0.0, url: $0.1) },
            scopes: subject.scopes, fields: subject.fields,
            libraryID: library.id, subjectName: subject.displayName, services: services)
        else { return }
        _ = try await commands.run(command)
        await reload()
    }

    private func reload() async {
        guard case .ready(let subject) = state, let services, let library else { return }
        guard let scopes = try? await services.protectedScopes(ids: subject.fileIDs) else { return }
        state = .ready(Subject(fileIDs: subject.fileIDs, urls: subject.urls,
                               displayName: subject.displayName, fields: subject.fields,
                               scopes: scopes))
        _ = library
    }
}
