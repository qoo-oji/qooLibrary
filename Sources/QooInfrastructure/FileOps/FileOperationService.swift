import AppKit
import Foundation
import QooKit

/// **ファイルシステムへの変更はすべてこのサービスを経由する** [FO-01]。
/// 他のレイヤから `FileManager` の変更系 API を呼んではならない。CI の静的検査
/// （`Scripts/check-fileops-isolation.swift`、B-10）が `QooInfrastructure/FileOps/`
/// 以外からの呼び出しを検出したらビルドを失敗させる [FO-02]。
///
/// フェーズ 1 (1-5) の時点では `ExpectedChangeLedger`（自己変更識別、2-2 で実装）・
/// `CommandStack`/操作履歴（1-11 で実装）・`NotificationRouter`（1-12b で実装）は
/// まだ無いため、`OpReceipt` を返すところまでを担う。呼び出し側がそれを使って
/// Undo を組み立てる、という設計 [FS2-01] はそのまま踏襲している。
public actor FileOperationService {
    /// アプリ全体で単一のインスタンスを使う想定（`CommandStack.shared`/`LockManager.shared`
    /// と同じ方針 [11章 §11.2, §11.3]）。テストでは `init()` で独立インスタンスを作れる。
    public static let shared = FileOperationService()

    public init() {}

    // MARK: - 基本操作 [7.1 節]

    @discardableResult
    public func createDirectory(at url: URL, options: OpOptions = .init()) async throws -> OpReceipt {
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

    @discardableResult
    public func rename(_ item: URL, to newName: String, options: OpOptions = .init()) async throws -> OpReceipt {
        let target = item.deletingLastPathComponent().appendingPathComponent(newName)
        guard let finalTarget = try await resolveDestination(item, target, options: options) else {
            throw FileOperationError.operationFailed("rename of \(item.path) skipped by conflict policy")
        }
        let before = try? identity(of: item)
        try FileManager.default.moveItem(at: item, to: finalTarget) // [FM-05]
        return OpReceipt(before: before, after: try? identity(of: finalTarget), fromURL: item, toURL: finalTarget, kind: .rename)
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
            guard let finalTarget = try await resolveDestination(item, target, options: options) else {
                continue // [ConflictPolicy.skip]
            }
            let before = try? identity(of: item)
            try perform(item, finalTarget)
            receipts.append(OpReceipt(before: before, after: try? identity(of: finalTarget), fromURL: item, toURL: finalTarget, kind: kind))
        }
        return receipts
    }

    /// 衝突判定と解決 [7.1 節]。戻り値が `nil` の場合はその項目をスキップする。
    private func resolveDestination(_ source: URL, _ destination: URL, options: OpOptions) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }

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
            try FileManager.default.removeItem(at: destination) // [FM-13]
            return destination
        case .keepBoth:
            return nextAvailableName(for: destination) // [CF-01]
        case .skip:
            return nil
        }
    }

    /// Finder に倣い `name 2.ext` `name 3.ext` の形式で連番を付与する [CF-01]。
    private func nextAvailableName(for url: URL) -> URL {
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
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

    private func identity(of url: URL) throws -> FileIdentity {
        let volumeUUID = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? ""
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else {
            throw FileOperationError.operationFailed("stat failed for \(url.path)")
        }
        return FileIdentity(volumeUUID: volumeUUID, inode: UInt64(statInfo.st_ino))
    }
}
