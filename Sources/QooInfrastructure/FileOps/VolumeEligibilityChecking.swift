import Foundation
import QooKit

/// フォルダ登録の前段で必ず通すファイルシステム適合検証 [FS-01〜FS-09]。
public struct VolumeCapability: Sendable, Equatable {
    public let volumeUUID: String // .volumeUUIDStringKey [VD-02]
    public let fileSystemName: String // .volumeLocalizedFormatDescriptionKey
    public let supportsPersistentIDs: Bool // .volumeSupportsPersistentIDsKey [FS-02]
    public let isNetworkVolume: Bool // .volumeIsLocalKey == false [FS-06]
    public let isReadOnly: Bool

    public init(
        volumeUUID: String,
        fileSystemName: String,
        supportsPersistentIDs: Bool,
        isNetworkVolume: Bool,
        isReadOnly: Bool
    ) {
        self.volumeUUID = volumeUUID
        self.fileSystemName = fileSystemName
        self.supportsPersistentIDs = supportsPersistentIDs
        self.isNetworkVolume = isNetworkVolume
        self.isReadOnly = isReadOnly
    }
}

public enum VolumeWarning: Sendable, Equatable {
    case networkVolumeFSEventsUnreliable // [FS-06]
}

public enum VolumeRejection: Sendable, Equatable {
    case noPersistentFileID(fileSystem: String) // [FS-01][FS-04]
    case persistentIDNotPreserved(fileSystem: String) // FS-03 実測が失敗
}

public enum VolumeEligibility: Sendable, Equatable {
    case eligible(warnings: [VolumeWarning])
    case rejected(reason: VolumeRejection)
}

public enum VolumeEligibilityError: Error, Sendable, Equatable {
    /// FS-03 実測用の一時ファイルを作成できなかった。
    case probeSetupFailed(errnoCode: Int32)
    /// 読み取り専用のボリューム。登録しても書き込めないため受け付けない。
    case readOnlyVolume(fileSystem: String)
}

/// **`LocalizedError` に準拠させる理由** [ER-03]［監査で発見］。準拠して
/// いなかったため、フォルダ登録の失敗がそのままユーザーに出ると
/// 「操作を完了できませんでした。（QooInfrastructure.VolumeEligibilityError
/// エラー0）」という、原因が一切分からない既定文言になっていた
/// （`FileOperationError`/`ExtractError` で踏んだのと同じ落とし穴）。
extension VolumeEligibilityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .probeSetupFailed(code):
            return "このフォルダを登録できるか確認できませんでした。\(PosixFailure.explain(code))"
        case let .readOnlyVolume(fileSystem):
            return "このフォルダは読み取り専用のボリューム（\(fileSystem)）にあるため登録できません。"
                + "書き込みできるボリューム上のフォルダを選んでください。"
        }
    }
}

public protocol VolumeEligibilityChecking: Sendable {
    func capability(of url: URL) throws -> VolumeCapability
    /// FS-02 の宣言値に加え、FS-03 の実測（作成→移動→ID 再取得）を行う。
    func evaluate(_ url: URL) async throws -> VolumeEligibility
}
