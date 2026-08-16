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
        // **読み取り専用は先に断る**［監査で発見］。`isReadOnly` は以前から
        // 計算されていたのに誰も読んでおらず、読み取り専用ボリュームを登録
        // しようとすると下の実測用ファイルの作成が失敗して
        // `probeSetupFailed`（当時は文言も無し）になっていた。原因が
        // 「読み取り専用だから」だと分かる形で、先に止める。
        guard !cap.isReadOnly else {
            throw VolumeEligibilityError.readOnlyVolume(fileSystem: cap.fileSystemName)
        }
        // **`supportsPersistentIDs` で門前払いしない** [NV3-02]。
        //
        // このフラグは**両方向に間違う**ことを 1-16b の実測で確認した
        // （8章 §8.11.3）:
        //
        // | サーバ | フラグ | 実際の同一性 | |
        // |---|---|---|---|
        // | Samba(QNAP) | × | × | 一致 |
        // | Apple SMB | ○ | ○ | 一致 |
        // | **Windows(NTFS)** | **×** | **○** | **偽陰性** |
        //
        // Windows 共有は `supportsPersistentIDs = ×` を返すのに、実際には
        // NTFS の File Reference Number がそのまま渡り、改名・移動で不変、
        // 再利用時は sequence number が増えるため誤同定も起きない。
        // ここで `guard` していたため、**実際には使える共有を誤って拒否**していた。
        //
        // 一方、下の FS-03 実測プローブ（作成→移動→ID 再取得）は
        // **3 系統すべてを正しく分類できた**。判定はそちらに一本化する。
        // これは「能力フラグを『できない証明』に使わない」[NV-80] の実例。

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
            // `createFile` は失敗を Bool でしか返さないため、直後の `errno` を
            // 読んで理由（権限・容量・読み取り専用など）を残す [ER-03]。
            throw VolumeEligibilityError.probeSetupFailed(errnoCode: errno)
        }
        let idA = probeIdentity(of: tmpA)
        try fm.moveItem(at: tmpA, to: tmpB)
        let idB = probeIdentity(of: tmpB)

        // 2 つの拒否理由を**実測の結果で**使い分ける。フラグではなく、
        // 実際に何が起きたかで説明する。
        guard idA.isMeaningful else {
            // ID をそもそも取れない。
            return .rejected(reason: .noPersistentFileID(fileSystem: cap.fileSystemName))
        }
        guard idA == idB else {
            // 取れるが移動で変わってしまう（Samba 系がここに落ちる）。
            return .rejected(reason: .persistentIDNotPreserved(fileSystem: cap.fileSystemName))
        }

        var warnings: [RegistrationWarning] = []
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
