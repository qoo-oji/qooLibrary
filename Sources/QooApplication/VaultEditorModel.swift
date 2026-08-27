//
//  右ペインの保管庫 [FA-01][FA-07][DT-11]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（出す向き・オフラインでの
//  見せ方・DB に行が無いときの扱い）を自動テストで固定できなくなる
//  （`RatingEditorModel` と同じ理由）。SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 右ペインが 1 つ持つ、選択中のファイルの保管庫の状態。
@MainActor
@Observable
public final class VaultEditorModel {
    public enum State: Sendable, Equatable {
        /// ライブラリ経由で開いていない、またはライブラリ機能が使えない。
        /// **枠ごと出さない** [LF-01 と同じ判断]。
        case notApplicable
        case loading
        /// ライブラリの中だが DB に行が無い。**枠ごと出さない**
        /// ——評価 [RA-01] と違って理由を書いても次の手が無い（保管庫は
        /// 蔵書だけの機能で、取り込ませる操作はここには無い）。
        case notInLibrary
        case ready(Subject)
        case failed(String)
    }

    public struct Subject: Sendable, Equatable {
        public let id: FileID
        public let url: URL
        public let displayName: String
        public let relativePath: String
        public let isArchived: Bool
        /// 保管庫へ移す前の場所 [FA-04][DT-11]。記録が無ければ現在のパスから
        /// 導く [FA-03]。保管庫の外にいるときは `nil`。
        public let archivedFromPath: String?
        public let archivedAt: Date?
        /// ボリュームが繋がっているか。**実ファイルを動かす操作なので要る**
        /// ——ラベルの保管庫 [LA-01] が DB だけを触るのとは事情が違う。
        public let isOnline: Bool

        public init(id: FileID, url: URL, displayName: String, relativePath: String,
                    isArchived: Bool, archivedFromPath: String?, archivedAt: Date?,
                    isOnline: Bool) {
            self.id = id
            self.url = url
            self.displayName = displayName
            self.relativePath = relativePath
            self.isArchived = isArchived
            self.archivedFromPath = archivedFromPath
            self.archivedAt = archivedAt
            self.isOnline = isOnline
        }
    }

    public private(set) var state: State = .notApplicable

    private let commands: CommandStack
    private var services: LibraryServices?
    private var library: LibrarySummary?
    private var loadedURL: URL?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    public func load(url: URL?, library: LibrarySummary?, services: LibraryServices) async {
        self.services = services
        self.library = library
        guard let url, let library, services.isReady else {
            loadedURL = nil
            state = .notApplicable
            return
        }
        if loadedURL != url {
            state = .loading
            loadedURL = url
        }
        do {
            guard let row = try await services.fileRow(at: url, in: library) else {
                state = .notInLibrary
                return
            }
            state = .ready(Subject(
                id: row.id, url: url, displayName: row.filename,
                relativePath: row.relativePath,
                isArchived: row.isArchived,
                archivedFromPath: row.isArchived
                    ? (row.archivedFromPath ?? VaultPath.original(row.relativePath))
                    : nil,
                archivedAt: row.archivedAt,
                isOnline: library.isOnline))
        } catch {
            // **取り消しは失敗ではない**（`RatingEditorModel` と同じ）。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    /// 保管庫へ出し入れする [FA-01][FA-07]。
    public func toggleArchived() async throws {
        guard case .ready(let subject) = state, let library, subject.isOnline else { return }
        let command = SetFileArchivedCommand(
            targets: [SetFileArchivedCommand.Target(
                id: subject.id, relativePath: subject.relativePath,
                archivedFromPath: subject.archivedFromPath,
                archivedAt: subject.archivedAt)],
            archived: !subject.isArchived,
            root: URL(fileURLWithPath: library.resolvedPath))
        _ = try await commands.run(command)
    }
}
