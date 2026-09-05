//
//  ファイル保管庫の出し入れ [FA-01〜FA-16][FDA-01〜FDA-02]。DB 操作の Undo の 5・6 つ目。
//
import Foundation
import QooInfrastructure
import QooKit

/// ファイルを保管庫へ入れる／から出す [FA-01][FA-07]。
///
/// **入れると出すを 1 つのコマンドにしてある**［`SetLabelArchivedCommand` と
/// 同じ形］。違うのは行き先の組み立て方だけで、実ファイルの運び方・
/// サイドカーの連動・空フォルダの後始末・DB の書き方はまったく同じ。
/// 2 つ書くと、片方だけ直して取り残す——このコードベースが 5 度踏んでいる形。
public final class SetFileArchivedCommand: Command {

    /// 運ぶ 1 件。**呼び出し側が DB から読んだ値をそのまま渡す**——
    /// コマンドの中で引き直すと、押した瞬間と実行の間に走査が挟まったときに
    /// 「見ていたのと違う行」を動かすことになる。
    public struct Target: Sendable, Hashable {
        public let id: FileID
        /// 現在の相対パス（ライブラリ根から）。
        public let relativePath: String
        /// 保管庫から出すときの戻り先 [FA-04]。`nil` なら現在のパスから導く
        /// [FA-03] ——外部で `.qooarchive` へ入れられたものには記録が無い。
        public let archivedFromPath: String?
        /// 保管庫へ入れた日時 [FAW-05]。**⌘Z で「戻す」を取り消したときに
        /// 元の日時へ戻すため**に控える。
        public let archivedAt: Date?

        public init(id: FileID, relativePath: String,
                    archivedFromPath: String? = nil, archivedAt: Date? = nil) {
            self.id = id
            self.relativePath = relativePath
            self.archivedFromPath = archivedFromPath
            self.archivedAt = archivedAt
        }
    }

    private struct Moved {
        let id: FileID
        let from: String
        let to: String
        /// 実行前に DB が持っていた `archivedAt`。undo で書き戻す。
        let previousArchivedAt: Date?
    }

    private let targets: [Target]
    private let archived: Bool
    private let root: URL
    private let services: LibraryServices
    private let fileOps: FileOperationService
    private var moved: [Moved] = []

    public init(targets: [Target], archived: Bool, root: URL,
                services: LibraryServices = .shared,
                fileOps: FileOperationService = .shared) {
        self.targets = targets
        self.archived = archived
        self.root = root
        self.services = services
        self.fileOps = fileOps
    }

    public var displayName: String {
        let verb = archived ? "保管庫に移動" : "保管庫から戻す"
        if targets.count == 1 {
            return "「\((targets[0].relativePath as NSString).lastPathComponent)」を\(verb)"
        }
        return "\(targets.count) 件のファイルを\(verb)"
    }

    public var logDescription: String {
        let verb = archived ? "vault-archive" : "vault-restore"
        let paths = targets.prefix(3)
            .map { Log.path(root.appendingPathComponent($0.relativePath)) }
            .joined(separator: ", ")
        return "\(verb) (\(targets.count) 件): \(paths)"
    }

    /// 既定実装は `logDescription` の先頭 3 件しか拾えない [OH-01]。
    /// **保管庫へはフォルダ単位で何十件も動く。**
    public var logTargets: [String] {
        targets.map { root.appendingPathComponent($0.relativePath).path }
    }

    public let isUndoable = true
    public let completionSound: SystemSoundEffect? = .operationComplete

    public func execute() async throws -> CommandResult {
        moved = []
        var failed: [FailedItem] = []
        var prunes: Set<URL> = []

        for target in targets {
            if Cancellation.isRequested { break }
            guard let destination = Self.destination(for: target, archived: archived) else {
                continue // 既にその側にある——運ぶものが無い
            }
            let source = root.appendingPathComponent(target.relativePath)
            do {
                let relocation = try await FileVault.relocate(
                    from: target.relativePath, to: destination, root: root, fileOps: fileOps)
                moved.append(Moved(id: target.id, from: target.relativePath,
                                   to: relocation.to,
                                   previousArchivedAt: target.archivedAt))
                Self.collectPrunes(&prunes, source: source)
            } catch let error where CommandStack.isCancellation(error) {
                break
            } catch {
                failed.append(FailedItem(item: source.lastPathComponent,
                                         reason: error.localizedDescription))
            }
        }

        // **実体が動いたあとは投げない**［レビューで発見］。`CommandStack.run` は
        // `execute()` が投げると**スタックへ積まない**ので、投げ返すと
        // 「ファイルは `.qooarchive` へ移ったのに ⌘Z で戻せない」状態になる
        // ——`MoveFilesCommand` が `PartialTransferFailure` を引き取るのと
        // 同じ理由 [ER-13][ER-16]。部分的な成功として返せば、スタックにも
        // 操作履歴にも載り、呼び出し側が理由を提示する [ER-12][ER-14]。
        do {
            try await writeMoves(archived: archived)
        } catch {
            guard !moved.isEmpty else { throw error }
            failed.append(FailedItem(item: root.lastPathComponent,
                                     reason: error.localizedDescription))
            await FileVault.pruneEmptyFolders(Array(prunes), root: root, fileOps: fileOps)
            return .partial(succeeded: moved.count, failed: failed)
        }
        // 空になったフォルダの後始末は**最後に 1 回** [FA-06][FA-08][FA-16]。
        // 1 件ごとに親を辿ると、同じフォルダから 100 件運んだときに 100 回
        // 同じ場所を確かめることになる。
        await FileVault.pruneEmptyFolders(Array(prunes), root: root, fileOps: fileOps)

        if failed.isEmpty, moved.count == targets.count { return .success }
        return .partial(succeeded: moved.count, failed: failed)
    }

    public func undo() async throws -> UndoResult {
        guard !moved.isEmpty else { return .impossible(reason: "元に戻す対象がありません") }
        var reverted: [Moved] = []
        var failed: [FailedItem] = []
        var prunes: Set<URL> = []

        for item in moved.reversed() {
            let source = root.appendingPathComponent(item.to)
            do {
                let relocation = try await FileVault.relocate(
                    from: item.to, to: item.from, root: root, fileOps: fileOps)
                reverted.append(Moved(id: item.id, from: item.to, to: relocation.to,
                                      previousArchivedAt: item.previousArchivedAt))
                Self.collectPrunes(&prunes, source: source)
            } catch {
                failed.append(FailedItem(item: source.lastPathComponent,
                                         reason: error.localizedDescription))
            }
        }

        if !reverted.isEmpty {
            // **元の日時へ戻す** [FAW-05]。「戻す」を取り消して保管庫へ返した
            // ときに「今」を書くと、日時での並べ替えが実態とずれる。
            let vaultMoves = reverted.map {
                VaultMove(id: $0.id, relativePath: $0.to, previousPath: $0.from,
                          archivedAt: $0.previousArchivedAt ?? Date())
            }
            do {
                try await services.setFileArchived(vaultMoves, archived: !archived)
            } catch {
                // **実体は戻っているので投げない**（`execute()` と同じ理由）。
                // 投げると「ファイルは元の場所に戻ったのに、取り消しは失敗した
                // ことになっている」という、画面と実態が食い違う状態になる。
                // DB のパスは次の走査が inode で引き直して直す [ID-02]。
                failed.append(FailedItem(item: root.lastPathComponent,
                                         reason: error.localizedDescription))
            }
        }
        await FileVault.pruneEmptyFolders(Array(prunes), root: root, fileOps: fileOps)

        // 戻せた分だけ `moved` から外す——半端な状態で再度 ⌘Z を押しても、
        // 既に戻したものをもう一度動かさない。
        let revertedIDs = Set(reverted.map(\.id))
        moved.removeAll { revertedIDs.contains($0.id) }

        if failed.isEmpty { return .complete }
        return .partial(succeeded: reverted.count, failed: failed)
    }

    // MARK: - 内部

    private func writeMoves(archived: Bool) async throws {
        guard !moved.isEmpty else { return }
        let vaultMoves = moved.map {
            VaultMove(id: $0.id, relativePath: $0.to, previousPath: $0.from,
                      archivedAt: Date())
        }
        try await services.setFileArchived(vaultMoves, archived: archived)
    }

    /// 行き先。既にその側にあるなら `nil`（運ぶものが無い）。
    ///
    /// **`nonisolated`。** `Command` は `@MainActor` なので、素のままだと
    /// この `static` も隔離されてテストから同期的に呼べない
    /// （`LibraryContentModel.makeQuery` で踏んだのと同じ罠）。
    nonisolated static func destination(for target: Target, archived: Bool) -> String? {
        if archived {
            guard !VaultPath.isInside(target.relativePath) else { return nil }
            return VaultPath.archived(target.relativePath)
        }
        // 記録があればそこへ [FA-04]。無ければ現在のパスから導く [FA-03]。
        if let recorded = target.archivedFromPath, !recorded.isEmpty { return recorded }
        return VaultPath.original(target.relativePath)
    }

    /// 運び元の親と、その `covers` を後始末の起点に加える [FA-16]。
    nonisolated static func collectPrunes(_ prunes: inout Set<URL>, source: URL) {
        let parent = source.deletingLastPathComponent()
        prunes.insert(parent)
        prunes.insert(parent.appendingPathComponent("covers", isDirectory: true))
    }
}

/// フォルダを丸ごと保管庫へ移す [FDA-01][FDA-02][FDA-03]。
///
/// **1 回の移動で運ぶ。** 配下を 1 件ずつ運ぶと、DB に載っていないもの
/// （`covers` の画像・対象拡張子外のファイル）が置き去りになり、「丸ごと」に
/// ならない。配下の行の相対パスは、着地点からの差し替えで写す。
///
/// **「フォルダを保管庫から戻す」は提供しない** [FDA-04]。格納されていた
/// ファイルをすべて戻せば同じ結果になるので、整理ウインドウ側は
/// ファイル単位でだけ扱う [FDA-05]。ただし**このコマンドの ⌘Z は効く**
/// ——取り消しは「戻す機能」ではなく、直前の操作を無かったことにするもの。
public final class ArchiveFolderCommand: Command {
    private let libraryID: LibraryID
    private let folderRelativePath: String
    private let root: URL
    private let services: LibraryServices
    private let fileOps: FileOperationService

    /// 実行前の (行 → 相対パス)。undo で書き戻すために控える。
    private var containedBefore: [FileID: String] = [:]
    /// フォルダが実際に着地した相対パス（衝突すると連番が付く [FA-13]）。
    private var landedPath: String?

    public init(libraryID: LibraryID, folderRelativePath: String, root: URL,
                services: LibraryServices = .shared,
                fileOps: FileOperationService = .shared) {
        self.libraryID = libraryID
        self.folderRelativePath = folderRelativePath
        self.root = root
        self.services = services
        self.fileOps = fileOps
    }

    public var displayName: String {
        "「\((folderRelativePath as NSString).lastPathComponent)」を保管庫に移動"
    }

    public var logDescription: String {
        "vault-archive-folder: \(Log.path(root.appendingPathComponent(folderRelativePath)))"
    }

    public let isUndoable = true
    public let completionSound: SystemSoundEffect? = .operationComplete

    public func execute() async throws -> CommandResult {
        // **運ぶ前に控える**——運んだあとでは、どの行が中に居たかを
        // 相対パスから引けない（もう別の場所を指している）。
        containedBefore = try await services.filesUnder(libraryID: libraryID,
                                                        folderRelativePath: folderRelativePath)
        let destination = VaultPath.archived(folderRelativePath)
        let relocation = try await FileVault.relocate(
            from: folderRelativePath, to: destination, root: root, fileOps: fileOps)
        landedPath = relocation.to

        // **実体が動いたあとは投げない**（`SetFileArchivedCommand` と同じ理由）
        // ——投げ返すと Undo スタックへ積まれず、フォルダが `.qooarchive` へ
        // 移ったまま戻せなくなる。
        var failed: [FailedItem] = []
        do {
            try await rewrite(oldPrefix: folderRelativePath, newPrefix: relocation.to,
                              archived: true)
        } catch {
            failed.append(FailedItem(item: (folderRelativePath as NSString).lastPathComponent,
                                     reason: error.localizedDescription))
        }
        await FileVault.pruneEmptyFolders(
            [root.appendingPathComponent(folderRelativePath).deletingLastPathComponent()],
            root: root, fileOps: fileOps)
        return failed.isEmpty ? .success
                              : .partial(succeeded: containedBefore.count, failed: failed)
    }

    public func undo() async throws -> UndoResult {
        guard let landedPath else { return .impossible(reason: "元に戻す対象がありません") }
        let relocation = try await FileVault.relocate(
            from: landedPath, to: folderRelativePath, root: root, fileOps: fileOps)
        try await rewrite(oldPrefix: landedPath, newPrefix: relocation.to, archived: false)
        await FileVault.pruneEmptyFolders(
            [root.appendingPathComponent(landedPath).deletingLastPathComponent()],
            root: root, fileOps: fileOps)
        self.landedPath = nil
        return relocation.to == folderRelativePath
            ? .complete
            // 元の名前で戻せなかった（同名のものが新しくできていた）[UD-07]
            : .partial(succeeded: containedBefore.count, failed: [])
    }

    private func rewrite(oldPrefix: String, newPrefix: String, archived: Bool) async throws {
        guard !containedBefore.isEmpty else { return }
        let moves = containedBefore.compactMap { id, path -> VaultMove? in
            guard let suffix = Self.suffix(of: path, under: oldPrefix) else { return nil }
            // 残りが空なのはフォルダ自身の行（ブックフォルダ [IF-01]）。
            let moved = suffix.isEmpty ? newPrefix : newPrefix + "/" + suffix
            return VaultMove(id: id, relativePath: moved,
                             previousPath: path, archivedAt: Date())
        }
        try await services.setFileArchived(moves, archived: archived)
        // 次の undo/redo のために、写した先を控え直す。
        containedBefore = Dictionary(uniqueKeysWithValues: moves.map { ($0.id, $0.relativePath) })
    }

    /// `path` が `folder` の配下なら、`folder/` を取り除いた残り。
    ///
    /// **素の `hasPrefix` では誤る**——`a/bc/x` が `a/b` の配下に見える。
    /// `nonisolated` の理由は `destination(for:archived:)` と同じ。
    nonisolated static func suffix(of path: String, under folder: String) -> String? {
        guard folder.isEmpty == false else { return path }
        // フォルダ自身の行はここで空文字になる。**ブックフォルダは 1 冊 = 1 行**
        // [IF-01] で、その `relativePath` はフォルダそのもの——配下だけを見ると、
        // 丸ごと運んだのに DB が古い場所を指したまま残る。
        if path == folder { return "" }
        let prefix = folder + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

/// 選択に対して保管庫のどちら向きの操作を出すか [FA-01][FA-07]。
///
/// **判断は相対パスだけで足りる**——保管庫にあるかは `.qooarchive` 配下に
/// あるかと同じ [SY-10] なので、DB へ問い合わせなくてもメニューの文言を
/// 決められる（コンテキストメニューの組み立てから `await` を追い出せる）。
public enum VaultDirection {
    /// `true` = 保管庫へ入れる／`false` = 出す／`nil` = 出さない。
    ///
    /// **混ざっているときは出さない。** 「入れる」と「出す」が同時に走る
    /// 1 つの項目は、押した結果が読めない。
    public static func forSelection(_ relativePaths: [String]) -> Bool? {
        guard !relativePaths.isEmpty else { return nil }
        let inside = relativePaths.filter(VaultPath.isInside).count
        if inside == 0 { return true }
        if inside == relativePaths.count { return false }
        return nil
    }
}
