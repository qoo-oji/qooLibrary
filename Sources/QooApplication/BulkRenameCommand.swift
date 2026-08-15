import Foundation
import QooInfrastructure
import QooKit

/// Finder 相当の一括リネームを 1 つの Undo 単位として実行する [BR-11]。
///
/// 名前の計算は `BulkRename`（`QooKit` の純粋関数）が済ませてある。ここが
/// 担うのは**順序**だけ — ただしその順序が肝心で、素直に上から実行すると
/// 「1→2, 2→3」のようなずらしで途中の項目を踏み潰す。
public final class BulkRenameCommand: Command {
    /// 一時名に使う接尾辞。万一プロセスが落ちて残った場合でも、それと
    /// 分かる名前にしておく（`SecureExtractor` の残存ステージングと同じ考え方）。
    private static let temporarySuffix = ".qoo-bulk-rename-tmp"

    private let folder: URL
    private let changes: [BulkRename.Change]
    private let fileOps: FileOperationService
    /// 実行後の「今の URL → 元の名前」。Undo で戻すために使う。
    private var applied: [(url: URL, originalName: String)] = []

    public init(folder: URL, changes: [BulkRename.Change], fileOps: FileOperationService = .shared) {
        self.folder = folder
        self.changes = changes.filter(\.isChanged)
        self.fileOps = fileOps
    }

    public var displayName: String {
        changes.count == 1
            ? "「\(changes[0].originalName)」の名前を変更"
            : "\(changes.count) 件の名前を変更"
    }

    public var logDescription: String {
        "bulkRename: \(changes.count) 件 in \(Log.path(folder))"
    }

    public let isUndoable = true
    public let completionSound: SystemSoundEffect? = .operationComplete

    public func execute() async throws -> CommandResult {
        guard !changes.isEmpty else { return .success }
        let plan = changes.map { (from: $0.originalName, to: $0.newName) }
        // 途中で失敗しても、そこまでに改名し終えた分は Undo で戻せる必要が
        // ある [レビューで発見]。進んだぶんをその都度受け取って記録する。
        applied = []
        try await rename(plan, twoPass: BulkRename.requiresTwoPass(changes)) { [weak self] done in
            self?.applied = done
        }
        return applied.count == changes.count
            ? .success
            : .partial(succeeded: applied.count, failed: [])
    }

    public func undo() async throws -> UndoResult {
        guard !applied.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        let plan = applied.map { (from: $0.url.lastPathComponent, to: $0.originalName) }
        let reverse = plan.map { BulkRename.Change(originalName: $0.from, newName: $0.to) }
        var restored: [(url: URL, originalName: String)] = []
        defer { applied = [] }
        try await rename(plan, twoPass: BulkRename.requiresTwoPass(reverse)) { restored = $0 }
        if restored.count == plan.count { return .complete }
        return .partial(
            succeeded: restored.count,
            failed: [FailedItem(item: folder.lastPathComponent, reason: "一部の名前を戻せませんでした")]
        )
    }

    /// `plan` の順に改名する。
    ///
    /// [BR-10] `twoPass` のときは、いったん全件を一意な一時名へ逃がしてから
    /// 目的の名前へ付け替える。「A→B, B→A」の入れ替えや「1→2, 2→3」の
    /// ずらしは、そうしないと途中で既存の項目とぶつかる。
    ///
    /// 戻り値は「新しい URL と、その項目の元の名前」。
    /// - Parameter onProgress: 済んだ分をその都度渡す。**途中で throw しても
    ///   呼び出し側が「どこまで進んだか」を持てる**ようにするため
    ///   [レビューで発見: 戻り値だけだと失敗時に成果がすべて失われ、
    ///   Undo できなくなる]。
    private func rename(
        _ plan: [(from: String, to: String)], twoPass: Bool,
        onProgress: @escaping ([(url: URL, originalName: String)]) -> Void
    ) async throws {
        var results: [(url: URL, originalName: String)] = []
        if twoPass {
            var staged: [(url: URL, target: String, originalName: String)] = []
            do {
                for entry in plan {
                    let temporary = UUID().uuidString + Self.temporarySuffix
                    let receipt = try await fileOps.rename(folder.appendingPathComponent(entry.from), to: temporary)
                    staged.append((url: receipt.toURL, target: entry.to, originalName: entry.from))
                }
            } catch {
                // **一時名のまま放置しない** [レビューで発見]。ここで失敗すると
                // `<uuid>.qoo-bulk-rename-tmp` という、ユーザーには意味の
                // 分からない名前のファイルが残る。逃がした分を元の名前へ戻す。
                for entry in staged.reversed() {
                    _ = try? await fileOps.rename(entry.url, to: entry.originalName)
                }
                throw error
            }
            for entry in staged {
                let receipt = try await fileOps.rename(entry.url, to: entry.target)
                results.append((url: receipt.toURL, originalName: entry.originalName))
                onProgress(results)
            }
        } else {
            for entry in plan {
                let receipt = try await fileOps.rename(folder.appendingPathComponent(entry.from), to: entry.to)
                results.append((url: receipt.toURL, originalName: entry.from))
                onProgress(results)
            }
        }
    }
}
