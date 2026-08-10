import Foundation

/// `VolumeEligibilityChecking` の既定実装。
///
/// FS-03 の実測（作成→移動→ID 再取得）はフォルダ登録より前に行うため、
/// `FileOperationService`（期待変更台帳・Undo・操作履歴の起点）を経由しない
/// [08章 §1.5 実測用の一時ファイルは処理終了時に必ず削除する [B-30]]。
/// この理由により、本ファイルは FileOps 隔離検査（B-10）の対象外ディレクトリ
/// （`QooInfrastructure/FileOps/`）に置く。
public struct VolumeEligibilityChecker: VolumeEligibilityChecking {
    public init() {}

    public func capability(of url: URL) throws -> VolumeCapability {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeSupportsPersistentIDsKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        return VolumeCapability(
            volumeUUID: values.volumeUUIDString ?? "",
            fileSystemName: values.volumeLocalizedFormatDescription ?? "unknown",
            supportsPersistentIDs: values.volumeSupportsPersistentIDs ?? false,
            isNetworkVolume: !(values.volumeIsLocal ?? true),
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }

    public func evaluate(_ url: URL) async throws -> VolumeEligibility {
        let cap = try capability(of: url)
        guard cap.supportsPersistentIDs else {
            return .rejected(reason: .noPersistentFileID(fileSystem: cap.fileSystemName))
        }

        let probeName = ".qoo-fsprobe-\(UUID().uuidString)"
        let tmpA = url.appendingPathComponent(probeName)
        let tmpB = url.appendingPathComponent(probeName + "-moved")
        let fm = FileManager.default

        defer {
            // [B-30] 異常終了で残った場合は次回起動時のクリーンアップ（RB-07 と同じ経路）で除去する。
            try? fm.removeItem(at: tmpA)
            try? fm.removeItem(at: tmpB)
        }

        guard fm.createFile(atPath: tmpA.path, contents: nil) else {
            throw VolumeEligibilityError.probeSetupFailed
        }
        let idA = probeIdentity(of: tmpA)
        try fm.moveItem(at: tmpA, to: tmpB)
        let idB = probeIdentity(of: tmpB)

        guard idA == idB, idA.isMeaningful else {
            return .rejected(reason: .persistentIDNotPreserved(fileSystem: cap.fileSystemName))
        }

        var warnings: [VolumeWarning] = []
        if cap.isNetworkVolume {
            warnings.append(.networkVolumeFSEventsUnreliable) // [FS-06]
        }
        return .eligible(warnings: warnings)
    }

    /// `.fileResourceIdentifierKey` と生の inode (`st_ino`) の両方を突き合わせる。
    /// 前者だけでは移動前後の同一性判定がファイルシステムによって不安定なことがあるため。
    private struct ProbeIdentity: Equatable {
        let resourceIdentifier: String?
        let inode: UInt64?

        var isMeaningful: Bool { resourceIdentifier != nil || inode != nil }
    }

    private func probeIdentity(of url: URL) -> ProbeIdentity {
        let resourceIdentifier = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))
            .flatMap { ($0.fileResourceIdentifier as? NSObject)?.description }

        var statInfo = stat()
        let inode: UInt64? = stat(url.path, &statInfo) == 0 ? UInt64(statInfo.st_ino) : nil

        return ProbeIdentity(resourceIdentifier: resourceIdentifier, inode: inode)
    }
}
