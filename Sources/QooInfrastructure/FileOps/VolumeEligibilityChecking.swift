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

/// 登録は通るが、**ユーザーに伝えるべきこと**。
///
/// - Note: ボリュームの性質から出るものだけではない。クラウド同期の配下かは
///   ボリュームからは分からず（File Provider は**起動ボリュームの UUID** を
///   返す。8章 §8.11.1）、`RegisteredFolderStore.register` が別途調べて足す。
///   だから型名は `Volume…` ではなく `Registration…` である。
public enum RegistrationWarning: Sendable, Equatable {
    case networkVolumeFSEventsUnreliable // [FS-06]
    /// クラウド同期（File Provider）の配下 [NV8-04]。`provider` は
    /// `OneDrive` 等。分からなければ `nil`。
    case cloudSyncedLocation(provider: String?)
}

public enum VolumeRejection: Sendable, Equatable {
    case noPersistentFileID(fileSystem: String) // [FS-01][FS-04]
    case persistentIDNotPreserved(fileSystem: String) // FS-03 実測が失敗
}

public enum VolumeEligibility: Sendable, Equatable {
    case eligible(warnings: [RegistrationWarning])
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
extension VolumeEligibilityError: UserPresentableError {
    public var whatHappened: String {
        switch self {
        case .probeSetupFailed: "このフォルダを登録できるか確認できませんでした。"
        case .readOnlyVolume: "このフォルダは登録できません。"
        }
    }

    public var whyItHappened: String {
        switch self {
        case let .probeSetupFailed(code):
            return PosixFailure.reason(code, context: .subject)
        case let .readOnlyVolume(fileSystem):
            return "読み取り専用のボリューム（\(fileSystem)）にあるため、"
                + "登録に必要な確認も、以降の書き込みもできません。"
        }
    }

    public var recoverySuggestions: [RecoveryAction] { [] }

    public var recoveryHint: String? {
        switch self {
        case let .probeSetupFailed(code): PosixFailure.recovery(code, context: .subject)
        case .readOnlyVolume: "書き込みできるボリューム上のフォルダを選んでください。"
        }
    }

    public var technicalDetail: String? {
        switch self {
        case let .probeSetupFailed(code): PosixFailure.technicalDetail(code)
        case .readOnlyVolume: nil
        }
    }

    public var severity: NotificationSeverity { .sheet }
}

extension VolumeEligibilityError: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public protocol VolumeEligibilityChecking: Sendable {
    func capability(of url: URL) throws -> VolumeCapability
    /// FS-02 の宣言値に加え、FS-03 の実測（作成→移動→ID 再取得）を行う。
    func evaluate(_ url: URL) async throws -> VolumeEligibility
}
