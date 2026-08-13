import Foundation

/// エラー・通知の提示強度 [13.1 節]。数値が小さいほど強く割り込む
/// 提示手段になる。`Comparable` はこの並び（1 が最も強い）に従う。
public enum NotificationSeverity: Int, Sendable, Comparable, CaseIterable {
    case appModal = 1 // 強度1: アプリモーダル（続行不可のみ）[ER-02]
    case sheet = 2 // 強度2: シート（判断が必要）
    case inline = 3 // 強度3: インライン
    case transient = 4 // 強度4: 一時通知（ステータスバー／トースト）
    case logOnly = 5 // 強度5: ログのみ [ER-01]

    public static func < (lhs: NotificationSeverity, rhs: NotificationSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// ユーザーに提示可能なエラー [13.1 節、ER-03]。フェーズ1の既存エラー型
/// （`FileOperationError`/`ExtractError`/`RegisteredFolderError` 等）はまだ
/// この protocol に準拠していない（三要素の文言を整備するコストが大きいため
/// 後日の課題として `CLAUDE.md` に記録している）。`NotificationRouter` 側に
/// 素の `Error` から最小限の `NotificationItem` を組み立てる補助を用意し、
/// 準拠済み・未準拠のどちらの呼び出し元にも対応する。
public protocol UserPresentableError: Error, Sendable {
    /// 何が起きたか（1 文）[ER-03]
    var whatHappened: String { get }
    /// なぜ起きたか [ER-03]
    var whyItHappened: String { get }
    /// 次に何ができるか（0..n 個の提案）[ER-03]
    var recoverySuggestions: [RecoveryAction] { get }
    /// 折りたたんで表示する技術詳細 [ER-03]
    var technicalDetail: String? { get }
    /// 提示強度 [13.1 節]
    var severity: NotificationSeverity { get }
}

public struct RecoveryAction: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let kind: Kind

    /// 仕様書の `Kind` には `.openWindow(WindowRoute)`/`.runCommand(ManualCommandID)`
    /// もあるが、`WindowRoute`（ウインドウルーティング基盤）も
    /// `ManualCommandID`（11章 §11.6 手動実行コマンド）もまだ実装されていない
    /// フェーズ1では組み込めないため、今すぐ使える3種類のみに絞っている
    /// [設計判断、実装が揃い次第この enum を拡張する]。
    public enum Kind: Sendable, Equatable {
        case retry
        case openSystemSettings(String)
        case dismiss
    }

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// `NotificationRouter.present` に渡す通知1件 [13.1 節]。仕様書の `target`
/// （ライブラリ／ファイル／処理名）・`operationLogID`（操作履歴へのリンク）は
/// それぞれ登録フォルダの `libraryID`・操作履歴の DB レコードが前提のため、
/// フェーズ1にはまだ無い（`target`/`operationLogID` を省いた最小構成）。
public struct NotificationItem: Sendable, Identifiable {
    public enum Category: Sendable {
        case error, warning, info // [NT-03]
    }

    public let id: UUID
    public let date: Date
    public let category: Category
    public let severity: NotificationSeverity
    public let title: String
    public let body: String
    public let technicalDetail: String?
    public let actions: [RecoveryAction]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: Category,
        severity: NotificationSeverity,
        title: String,
        body: String,
        technicalDetail: String? = nil,
        actions: [RecoveryAction] = []
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.severity = severity
        self.title = title
        self.body = body
        self.technicalDetail = technicalDetail
        self.actions = actions
    }
}
