import AppKit
import Foundation
import QooKit

/// **ファイルシステムへの変更はすべてこのサービスを経由する** [FO-01]。
/// 他のレイヤから `FileManager` の変更系 API を呼んではならない。CI の静的検査
/// （`Scripts/check-fileops-isolation.swift`、B-10）が `QooInfrastructure/FileOps/`
/// 以外からの呼び出しを検出したらビルドを失敗させる [FO-02]。
///
/// フェーズ 1 (1-5) の時点では `ExpectedChangeLedger`（自己変更識別、2-2 で実装）は
/// まだ無いため、`OpReceipt` を返すところまでを担う。呼び出し側（`QooApplication`
/// の `Command` 群、1-11 で実装）がそれを使って Undo を組み立てる、という設計
/// [FS2-01] はそのまま踏襲している。エラーの提示自体は呼び出し側が
/// `NotificationRouter`（1-12b で実装）経由で行う。
public actor FileOperationService {
    /// アプリ全体で単一のインスタンスを使う想定（`CommandStack.shared`/`LockManager.shared`
    /// と同じ方針 [11章 §11.2, §11.3]）。テストでは `init()` で独立インスタンスを作れる。
    public static let shared = FileOperationService()

    public init() {}

    // MARK: - 基本操作 [7.1 節]

    @discardableResult
    public func createDirectory(at url: URL, options: OpOptions = .init()) async throws -> OpReceipt {
        // `withIntermediateDirectories: true` は対象がすでに存在していても
        // エラーを投げない（Foundation の標準動作）。「新規フォルダ」は
        // Finder と同じく既存の同名項目との衝突をエラーとして扱うべきのため、
        // 事前に明示チェックする [実機検証で発見: 同名フォルダを重複作成しても
        // 何も起きなかった]。
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileOperationError.operationFailed("「\(url.lastPathComponent)」という名前の項目はすでに存在します。")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // [FM-01]
        return OpReceipt(before: nil, after: try? identity(of: url), fromURL: url, toURL: url, kind: .createDirectory)
    }

    public func copy(_ items: [URL], to destination: URL, options: OpOptions = .init()) async throws -> [OpReceipt] {
        try await transfer(items, to: destination, options: options, kind: .copy) { source, target in
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    public func move(_ items: [URL], to destination: URL, options: OpOptions = .init()) async throws -> [OpReceipt] {
        try await transfer(items, to: destination, options: options, kind: .move) { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    /// 展開のステージングディレクトリ直下の項目を最終位置へ移送する [EX-04]。
    /// `SecureExtractor` がすべての安全検証（EX-10〜EX-24）を終えた**後**に
    /// 呼ぶことが前提。ステージングディレクトリ自体の削除はここでは行わない
    /// （呼び出し側の責務、`SecureExtractor` 参照）。
    public func promoteFromStaging(
        _ staging: URL, to destination: URL, options: OpOptions = .init()
    ) async throws -> [OpReceipt] {
        let items = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return try await transfer(items, to: destination, options: options, kind: .promoteFromStaging) { source, target in
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    @discardableResult
    public func rename(_ item: URL, to newName: String, options: OpOptions = .init()) async throws -> OpReceipt {
        let target = item.deletingLastPathComponent().appendingPathComponent(newName)
        guard let resolved = try await resolveDestination(item, target, options: options) else {
            throw FileOperationError.operationFailed("rename of \(item.path) skipped by conflict policy")
        }
        let before = try? identity(of: item)
        try withReplaceBackupCleanup(resolved) {
            try FileManager.default.moveItem(at: item, to: resolved.target) // [FM-05]
        }
        return OpReceipt(before: before, after: try? identity(of: resolved.target), fromURL: item, toURL: resolved.target, kind: .rename)
    }

    public func trash(_ items: [URL], options: OpOptions = .init()) async throws -> [TrashReceipt] {
        var identities: [URL: FileIdentity] = [:]
        for item in items {
            identities[item] = try? identity(of: item)
        }
        // NSWorkspace.shared.recycle(_:completionHandler:) を使い、Finder の
        // 「元に戻す」と互換にする [FM-04][TR2-01]。
        let mapping = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL: URL], Error>) in
            NSWorkspace.shared.recycle(items) { urls, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: urls)
                }
            }
        }
        return items.compactMap { original in
            guard let id = identities[original] else { return nil }
            return TrashReceipt(originalURL: original, trashURL: mapping[original], identity: id)
        }
    }

    public func deletePermanently(_ items: [URL], options: OpOptions = .init()) async throws -> [OpReceipt] {
        var receipts: [OpReceipt] = []
        for item in items {
            let before = try? identity(of: item)
            try FileManager.default.removeItem(at: item) // [FM-14]
            receipts.append(OpReceipt(before: before, after: nil, fromURL: item, toURL: item, kind: .deletePermanently))
        }
        return receipts
    }

    /// Finder の「エイリアスを作成」相当。`URL.bookmarkData(options: .suitableForBookmarkFile)`
    /// で本物の Finder エイリアス（シンボリックリンクではない）を作る。
    @discardableResult
    public func createAlias(for source: URL, in destinationFolder: URL, options: OpOptions = .init()) async throws -> OpReceipt {
        let aliasName = "\(source.lastPathComponent) のエイリアス"
        let target = destinationFolder.appendingPathComponent(aliasName)
        guard let resolved = try await resolveDestination(source, target, options: options) else {
            throw FileOperationError.operationFailed("alias creation for \(source.path) skipped by conflict policy")
        }
        let bookmarkData = try source.bookmarkData(options: [.suitableForBookmarkFile])
        try withReplaceBackupCleanup(resolved) {
            try URL.writeBookmarkData(bookmarkData, to: resolved.target)
        }
        return OpReceipt(before: nil, after: try? identity(of: resolved.target), fromURL: source, toURL: resolved.target, kind: .createAlias)
    }

    /// Finder の「ロック」/「ロック解除」相当。
    public func setLocked(_ items: [URL], locked: Bool) async throws -> [OpReceipt] {
        var receipts: [OpReceipt] = []
        for item in items {
            var mutableItem = item
            var values = URLResourceValues()
            values.isUserImmutable = locked
            try mutableItem.setResourceValues(values)
            receipts.append(OpReceipt(before: try? identity(of: item), after: try? identity(of: item), fromURL: item, toURL: item, kind: .setLocked))
        }
        return receipts
    }

    public func restoreFromTrash(_ receipts: [TrashReceipt]) async throws -> [OpReceipt] {
        var results: [OpReceipt] = []
        for receipt in receipts {
            guard let trashURL = receipt.trashURL else { continue }
            try FileManager.default.moveItem(at: trashURL, to: receipt.originalURL) // [UD-08]
            results.append(OpReceipt(
                before: nil, after: try? identity(of: receipt.originalURL),
                fromURL: trashURL, toURL: receipt.originalURL, kind: .restoreFromTrash
            ))
        }
        return results
    }

    // MARK: - 内部処理

    private func transfer(
        _ items: [URL],
        to destination: URL,
        options: OpOptions,
        kind: OperationKind,
        perform: (URL, URL) throws -> Void
    ) async throws -> [OpReceipt] {
        var receipts: [OpReceipt] = []
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard let resolved = try await resolveDestination(item, target, options: options) else {
                continue // [ConflictPolicy.skip]
            }
            let before = try? identity(of: item)
            try withReplaceBackupCleanup(resolved) {
                try perform(item, resolved.target)
            }
            receipts.append(OpReceipt(before: before, after: try? identity(of: resolved.target), fromURL: item, toURL: resolved.target, kind: kind))
        }
        return receipts
    }

    /// `resolveDestination` の戻り値。`.replace` の場合、書き込みが失敗したときに
    /// 元へ戻せるよう退避先も一緒に返す。
    private struct ResolvedDestination {
        let target: URL
        let backupOfReplaced: URL?
    }

    /// 衝突判定と解決 [7.1 節]。戻り値が `nil` の場合はその項目をスキップする。
    private func resolveDestination(_ source: URL, _ destination: URL, options: OpOptions) async throws -> ResolvedDestination? {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return ResolvedDestination(target: destination, backupOfReplaced: nil)
        }

        var policy = options.conflictPolicy
        if policy == .ask {
            guard let resolver = options.conflictResolver else {
                throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
            }
            policy = await resolver(source, destination)
            guard policy != .ask else {
                throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
            }
        }

        switch policy {
        case .ask:
            throw FileOperationError.conflictResolutionRequired(source: source, destination: destination)
        case .replace:
            // [フェーズ1完了時のリソースリーク・ファイル安全性監査で追加、
            // ユーザー指摘: 「壊れたファイルで健康なファイルを書き潰してしまう
            // おそれはないか」] 既存の宛先ファイルを即座に削除せず、同じ
            // ディレクトリへ一時退避してから `perform` を呼ぶ。退避は同一
            // ディレクトリ内の `moveItem`（同一ボリュームなら実質 rename(2) で
            // 高速・原子的）で行う。`perform` が失敗した場合は
            // `withReplaceBackupCleanup` が退避先から元の場所へ戻すため、
            // 書き込み失敗時に新旧どちらのファイルも失われる事態を避けられる。
            // 退避ファイルは成功・失敗いずれの場合も後始末されるため通常は
            // 痕跡を残さないが、退避直後にアプリがクラッシュする等の極めて
            // まれなタイミングでは `.qoo-replace-backup-*` が残る可能性がある
            // （§3.12 の例外扱い、`SecureExtractor` の残存ステージングと同種の
            // リスクとして許容する — 中身は元ファイルそのものなので、万一残っても
            // 手動で拡張子を戻せば復元できる）。
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".qoo-replace-backup-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: destination, to: backup) // [FM-13]
            return ResolvedDestination(target: destination, backupOfReplaced: backup)
        case .keepBoth:
            return ResolvedDestination(target: nextAvailableName(for: destination), backupOfReplaced: nil) // [CF-01]
        case .skip:
            return nil
        }
    }

    /// `.replace` で退避したバックアップの後始末を一箇所に集約する。`operation` が
    /// 成功すればバックアップを削除し、失敗すればバックアップを元の場所へ書き戻して
    /// からエラーを再送出する（`.replace` 以外では `backupOfReplaced` が `nil` の
    /// ため何もしない）。
    private func withReplaceBackupCleanup<T>(_ resolved: ResolvedDestination, _ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            if let backup = resolved.backupOfReplaced {
                try? FileManager.default.removeItem(at: backup)
            }
            return result
        } catch {
            if let backup = resolved.backupOfReplaced {
                try? FileManager.default.removeItem(at: resolved.target) // 中途半端な書き込み結果があれば破棄
                try? FileManager.default.moveItem(at: backup, to: resolved.target)
            }
            throw error
        }
    }

    /// Finder に倣い `name 2.ext` `name 3.ext` の形式で連番を付与する [CF-01]。
    /// 衝突先の名前に既に連番サフィックス（例: `name 2`）が付いている場合はそれを
    /// 剥がしてから採番する。剥がさないと `name 2` との衝突のたびに末尾へさらに
    /// ` 2` が積み重なり `name 2 2` のようになってしまう。
    private func nextAvailableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let rawBase = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        let base = Self.strippingTrailingCopyNumber(from: rawBase)
        let directory = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }

    private static func strippingTrailingCopyNumber(from name: String) -> String {
        guard let range = name.range(of: #" \d+$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }

    private func identity(of url: URL) throws -> FileIdentity {
        let volumeUUID = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? ""
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else {
            throw FileOperationError.operationFailed("stat failed for \(url.path)")
        }
        return FileIdentity(volumeUUID: volumeUUID, inode: UInt64(statInfo.st_ino))
    }
}
