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
    /// 展開先ではなく**作業領域**（アプリコンテナ＝起動ボリューム）の空きが
    /// 足りない。展開は必ずいったんここへ書き出してから最終位置へ移すため、
    /// 展開先に十分な空きがあっても起動ボリュームが手薄だと実行できない。
    /// 展開先の不足とは対処法が違うので別のケースにしてある。
    case insufficientStagingSpace(required: Int64, available: Int64)
    case tooManyEntries(limit: Int) // [EX-21]
    case expansionLimitExceeded(limit: Int64) // [EX-20][EX-21]
    case compressionRatioExceeded(limit: Double) // [EX-20][EX-21]
    case cancelled // [EX-24]
    /// 展開先への書き込みそのものが失敗した（空き容量・権限・名前の長さ等）。
    /// **`backendFailure` と分けている理由**: あちらは libarchive/UnRAR の
    /// 英語メッセージをそのまま抱える「アーカイブ側の問題」で、こちらは
    /// 書き込み先の問題。ユーザーが取るべき行動がまったく違う。
    case writeFailed(reason: String)
    case backendFailure(String)
    /// `ArchiveReading.readEntry` 用 [9.6 節、サムネイル生成の単一エントリ読み込み]。
    case entryNotFound(String)
    /// `ArchiveReading.readEntry` 用。`IM-02`（1エントリの読み込み上限）超過。
    case entryReadLimitExceeded(limit: Int)
}

/// **`UserPresentableError` に準拠させる理由** [ER-03]。
///
/// 三要素（何が／なぜ／次に何ができるか）と技術詳細を**型として要求する**ので、
/// **新しいケースを足したときに文言を書き忘れられない**。以前は 1 本の文字列に
/// すべてを詰めており、libarchive の英語（「Write error」）がそのまま本文に
/// 混ざる・対処法が無いケースが 9 件ある、といった穴があった［棚卸しで発見］。
///
/// 文言は日本語のリテラル。この層は文字列カタログ（アプリターゲットの
/// リソース）を参照できないため［既知の限界、`FileOperationError` と同じ］。
extension ExtractError: UserPresentableError {
    public var whatHappened: String {
        switch self {
        case .unsupportedFormat: "この形式のアーカイブには対応していません。"
        case .passwordProtected: "このアーカイブはパスワードで保護されています。"
        case .incorrectPassphrase: "アーカイブを復号できませんでした。"
        case .insufficientFreeSpace: "展開先の空き容量が足りません。"
        case .insufficientStagingSpace: "起動ディスクの空き容量が足りません。"
        case .tooManyEntries: "アーカイブに含まれる項目が多すぎます。"
        case .expansionLimitExceeded: "展開後の大きさが上限を超えました。"
        case .compressionRatioExceeded: "圧縮率が上限を超えました。"
        case .cancelled: "処理を中断しました。"
        case .writeFailed: "展開先へ書き込めませんでした。"
        case .backendFailure: "アーカイブを読み書きできませんでした。"
        case let .entryNotFound(name): "アーカイブ内に「\(name)」が見つかりません。"
        case .entryReadLimitExceeded: "アーカイブ内の項目が大きすぎて読み込めません。"
        }
    }

    public var whyItHappened: String {
        let formatter = ByteCountFormatter()
        switch self {
        case .unsupportedFormat:
            return "zip・7z・rar・tar.gz のいずれでもないか、ファイルが壊れている可能性があります。"
        case .passwordProtected:
            return "中身を取り出すにはパスワードが要ります。"
        case .incorrectPassphrase:
            // 断定しない — 復号したデータが読めないことは分かっても、
            // 原因がパスワード違いか破損かはこの時点で区別できない
            // （従来型の ZIP 暗号化は 1 バイトの検査値しか持たないため特に）。
            return "パスワードが違うか、アーカイブが壊れています。"
        case let .insufficientFreeSpace(required, available):
            return "\(formatter.string(fromByteCount: required)) が必要ですが、"
                + "空きは \(formatter.string(fromByteCount: available)) しかありません。"
        case let .insufficientStagingSpace(required, available):
            return "展開はいったん起動ディスク上の作業領域へ書き出すため、展開先とは別に "
                + "\(formatter.string(fromByteCount: required)) が必要ですが、"
                + "空きは \(formatter.string(fromByteCount: available)) しかありません。"
        case let .tooManyEntries(limit):
            return "上限は \(Self.grouped(limit)) 件です。"
        case let .expansionLimitExceeded(limit):
            return "上限は \(formatter.string(fromByteCount: limit)) です。"
        case let .compressionRatioExceeded(limit):
            return "上限は \(Self.grouped(Int(limit))) 倍です。壊れているか、極端に膨らむアーカイブの可能性があります。"
        case .cancelled:
            return ""
        case let .writeFailed(reason):
            return reason
        case .backendFailure:
            return "アーカイブが壊れているか、対応していない機能が使われている可能性があります。"
        case .entryNotFound:
            return "アーカイブの中身が変わったか、一覧が古くなっている可能性があります。"
        case let .entryReadLimitExceeded(limit):
            return "1 項目あたりの読み込みは \(formatter.string(fromByteCount: Int64(limit))) までです。"
        }
    }

    public var recoverySuggestions: [RecoveryAction] { [] }

    /// 提案の文言（`FileOperationError` と同じ扱い。押して意味のある操作が
    /// 無いものはボタンにせず、本文の末尾に添える）。
    public var recoveryHint: String? {
        switch self {
        case .unsupportedFormat:
            return "別のアプリで開けるか確認してください。"
        case .passwordProtected, .incorrectPassphrase:
            return "パスワードを確認して、もう一度お試しください。"
        case .insufficientFreeSpace:
            return "不要な項目を削除して空きを増やすか、別の場所へ展開してください。"
        case .insufficientStagingSpace:
            return "起動ディスクの不要な項目を削除してから、もう一度お試しください。"
        case .tooManyEntries, .expansionLimitExceeded, .compressionRatioExceeded:
            return "この上限は環境設定の「圧縮／展開」で変更できます。"
        case .cancelled:
            return nil // 中断は失敗ではない。次の手を促さない
        case .writeFailed:
            return nil // 理由の側（`PosixFailure`）が既に対処を含む
        case .backendFailure:
            return "アーカイブを作り直すか、別のアプリで開けるか確認してください。"
        case .entryNotFound:
            return "一覧を最新にしてから、もう一度お試しください。"
        case .entryReadLimitExceeded:
            return nil
        }
    }

    /// 折りたたんで見せる技術詳細 [ER-03]。**本文には混ぜない** —
    /// libarchive/UnRAR が返すのは英語で、ユーザー向けの説明にはならない。
    public var technicalDetail: String? {
        switch self {
        case let .backendFailure(message): message
        default: nil
        }
    }

    public var severity: NotificationSeverity {
        // 中断はユーザー自身の操作。失敗として割り込まない。
        self == .cancelled ? .logOnly : .sheet
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// `localizedDescription`（ログ・`NSError` 経由の表示）でも三要素が読めるように
/// する。`UserPresentableError` は提示用で、ログはこちらを読むため。
extension ExtractError: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
