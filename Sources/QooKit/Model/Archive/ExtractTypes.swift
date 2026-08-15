import Foundation

/// 展開時にエントリを拒否した理由 [EX-10〜EX-13]。
public enum RejectionReason: Sendable, Equatable {
    case emptyName
    case absolutePath
    case parentTraversal
    case invalidCharacters
    case symlinkSkipped
    case specialEntry
    case escapesDestination
}

public struct ExtractRejection: Sendable, Equatable {
    public let entry: String
    public let reason: RejectionReason

    public init(entry: String, reason: RejectionReason) {
        self.entry = entry
        self.reason = reason
    }
}

/// APFS の大文字小文字非区別による衝突で連番を付与したエントリ [EX-15]。
public struct ExtractRename: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 展開の安全上限 [EX-20〜EX-22]。既定値は ``AppLimits/Extraction``。
/// 環境設定での変更を想定し値型で持ち回す。
public struct ExtractLimits: Sendable, Equatable {
    public var maxUncompressedBytes: Int64
    public var maxEntries: Int
    public var ratioWarn: Double
    public var ratioAbort: Double
    public var freeSpaceMargin: Int64

    public init(
        maxUncompressedBytes: Int64 = AppLimits.Extraction.defaultMaxUncompressedBytes,
        maxEntries: Int = AppLimits.Extraction.defaultMaxEntries,
        ratioWarn: Double = AppLimits.Extraction.defaultRatioWarn,
        ratioAbort: Double = AppLimits.Extraction.defaultRatioAbort,
        freeSpaceMargin: Int64 = AppLimits.Extraction.defaultFreeSpaceMargin
    ) {
        self.maxUncompressedBytes = maxUncompressedBytes
        self.maxEntries = maxEntries
        self.ratioWarn = ratioWarn
        self.ratioAbort = ratioAbort
        self.freeSpaceMargin = freeSpaceMargin
    }

    public static let `default` = ExtractLimits()
}

public struct ExtractOptions: Sendable {
    public var destination: URL
    public var encoding: String.Encoding?
    /// シンボリックリンクを展開するか。既定は展開せずスキップする [EX-12]。
    public var followSymlinks: Bool
    public var limits: ExtractLimits
    /// zip の暗号化エントリを復号するためのパスフレーズ [環境設定「圧縮／展開」
    /// タブ]。`nil`（既定）でパスワード保護されたアーカイブに遭遇すると
    /// `ExtractError.passwordProtected` を投げる。呼び出し側はこれを受けて
    /// ユーザーにパスワードを尋ね、`passphrase` を埋めて再試行する（毎回の
    /// 展開で一律にパスワード入力を求めない設計）。libarchive 自身は zip の
    /// エントリ一覧（ファイル名）は暗号化しないため、`listEntries` は
    /// パスフレーズ無しでも成功する。
    public var passphrase: String?
    /// 進み具合の報告先 [UI-09][A-04]。バックエンドは「何件目・何バイト目か」
    /// だけを報告し、総数は `SecureExtractor` が `ProgressThrottle` で足す。
    public var progress: ProgressReporter?
    /// 一時停止／再開 [ユーザー要望]。エントリの境界と書き出しの合間で待つ。
    public var pauseToken: PauseToken?

    public init(
        destination: URL,
        encoding: String.Encoding? = nil,
        followSymlinks: Bool = false,
        limits: ExtractLimits = .default,
        passphrase: String? = nil,
        progress: ProgressReporter? = nil,
        pauseToken: PauseToken? = nil
    ) {
        self.destination = destination
        self.encoding = encoding
        self.followSymlinks = followSymlinks
        self.limits = limits
        self.passphrase = passphrase
        self.progress = progress
        self.pauseToken = pauseToken
    }
}

public struct ExtractResult: Sendable, Equatable {
    public let extractedCount: Int
    public let rejected: [ExtractRejection]
    public let renamedForCaseCollision: [ExtractRename]
    public let totalBytesWritten: Int64
    /// 最終位置（`ExtractOptions.destination` 直下）に実際に作られたトップ
    /// レベルの項目 [1-11、`ExtractCommand` の Undo 用]。バックエンド
    /// （`LibarchiveBackend`/`UnrarBackend`）はステージング内で完結し最終位置を
    /// 知らないため関知しない（既定は空配列）。`SecureExtractor.extract()` が
    /// `promoteFromStaging` の結果からこのフィールドだけを埋めた結果を返す。
    public let createdURLs: [URL]

    public init(
        extractedCount: Int,
        rejected: [ExtractRejection],
        renamedForCaseCollision: [ExtractRename],
        totalBytesWritten: Int64,
        createdURLs: [URL] = []
    ) {
        self.extractedCount = extractedCount
        self.rejected = rejected
        self.renamedForCaseCollision = renamedForCaseCollision
        self.totalBytesWritten = totalBytesWritten
        self.createdURLs = createdURLs
    }
}

/// 展開処理全体を中断させるエラー [EX-20〜EX-24]。エントリ単位の問題は
/// 中断せず ``ExtractResult/rejected`` に記録するのみだが、ここに列挙した
/// ものは展開全体を継続できないため必ず中断する。
public enum ExtractError: Error, Sendable, Equatable {
    case unsupportedFormat
    /// パスワードで保護されたエントリに遭遇したが、パスフレーズが渡されて
    /// いない [AB-04][OS-09]。呼び出し側はこれを受けてユーザーにパスワード
    /// 入力を促し、`passphraseProvider` 経由で再試行する
    /// [環境設定「圧縮／展開」タブ、`ArchivePasswordSheet` 参照]。
    case passwordProtected
    /// パスフレーズを渡したが復号に失敗した（誤ったパスワード）。
    case incorrectPassphrase
    case insufficientFreeSpace(required: Int64, available: Int64) // [EX-23]
    case tooManyEntries(limit: Int) // [EX-21]
    case expansionLimitExceeded(limit: Int64) // [EX-20][EX-21]
    case compressionRatioExceeded(limit: Double) // [EX-20][EX-21]
    case cancelled // [EX-24]
    case backendFailure(String)
    /// `ArchiveReading.readEntry` 用 [9.6 節、サムネイル生成の単一エントリ読み込み]。
    case entryNotFound(String)
    /// `ArchiveReading.readEntry` 用。`IM-02`（1エントリの読み込み上限）超過。
    case entryReadLimitExceeded(limit: Int)
}
