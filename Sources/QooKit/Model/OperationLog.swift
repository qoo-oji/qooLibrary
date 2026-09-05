//
//  操作履歴 [HS-01〜HS-04][OH-01〜OH-06][15章 §15.13]。
//
//  **プロトコルと値型は `QooKit`、実体は `QooPersistence` の `operationLog`
//  テーブル** [07章 §7.3]。書き手は `CommandStack.record()`（`QooApplication`）と
//  走査の結果 [OH-03] の 2 経路だけで、記録を機能ごとに散らさない
//  [FO-03 の精神。通知履歴が `NotificationRouter` 1 箇所に集めているのと同じ]。
//
//  ## 通知履歴 [NT-01〜NT-08] との違い
//  同じ「ユーザー向けの記録」でも役割が別物なので、テーブルもウインドウも
//  分けてある [NT-08 が診断ログとの違いを定めているのと同じ理由]。
//
//  | | 通知履歴 | 操作履歴 |
//  |---|---|---|
//  | 何の記録か | アプリが**知らせたこと** | 利用者が**したこと** |
//  | 消せるか | 消せる（読み終えた知らせ） | **消せない**（下記）|
//  | 既定の保持 | 30 日 [NT-07] | **90 日** [HS-04] |
//
//  ## 何を記録するか［ユーザー判断、2026-09］
//  **`CommandStack` を通る操作は種別を問わずすべて記録し、絞り込みは画面で行う。**
//  要件 HS-01 / OH-01 は「すべての**破壊的**操作」と定めるが、コマンドは 33 種
//  あり「破壊的」の線引きは一義に決まらない——判定を各コマンドへ持たせると、
//  新しいコマンドを足す人が忘れて**記録が黙って欠ける**。`record()` は run /
//  undo / redo のすべてが通る 1 箇所なので、そこで無条件に書くのが構造的に
//  漏れない（通知履歴が「全強度を記録し、未読に数えるのは 4 以上だけ」に
//  改訂したのとまったく同じ構図）。
//
//  ## 消せないこと［設計判断］
//  通知履歴には選択削除・全削除がある [NW-06] が、**こちらには作らない。**
//  あちらは「読み終えた知らせを捨てる」もので、こちらは「何をしたか」の記録
//  ——消せると `R-02`（自動リネーム・一括移動の誤設定で大量のファイル名を
//  破壊する）の裏付けが、事故を起こした本人の手で消せてしまう。掃除は
//  保持期間と件数の上限 [HS-04] だけが行う。
//
import Foundation

/// 操作履歴の 1 行が何の記録か。
///
/// **「取り消した」を元の行への印ではなく、新しい行として足す**
/// ［ユーザー判断、2026-09］。`operationLog.undone`（真偽値 1 列）は v1 から
/// あるが**使わない**——`.undonePartially` / `.undoFailed` / `.redone` は
/// 印 1 つでは表せず、結局は種別の列が要る。追記なら「取り消したがやり直した」
/// 「取り消しに失敗した」という経緯がそのまま残り、採番した行 ID を
/// コマンドに覚えさせて書き戻す必要も無い。
public enum OperationLogKind: String, Sendable, CaseIterable, Codable {
    case executed
    case failed
    case cancelled
    case undone
    case undonePartially
    case undoFailed
    case redone
    case redoFailed
    /// 走査の結果 [OH-03]。`CommandStack` を通らない唯一の種別。
    case scan

    public var group: OperationLogGroup {
        switch self {
        case .executed, .redone: .executed
        case .undone, .undonePartially: .undone
        case .failed, .undoFailed, .redoFailed: .unsuccessful
        case .cancelled: .cancelled
        case .scan: .scan
        }
    }
}

/// 左ペインの絞り込み [OH-02]。
///
/// **中断を失敗と同じ区画に入れない**——中断はユーザー自身の意思で、
/// `CommandStack.isCancellation` も同じ理由で失敗と分けている（既定の
/// ログレベルしか出していない環境で、キャンセルの記録に本当の失敗が
/// 埋もれるのを避けるため）。
public enum OperationLogGroup: String, Sendable, CaseIterable, Identifiable, Codable {
    case executed
    case undone
    case unsuccessful
    case cancelled
    case scan

    public var id: String { rawValue }
}

/// 履歴に残った操作 1 件。
public struct OperationLogEntry: Sendable, Hashable, Identifiable {
    public let id: OperationLogID
    public let date: Date
    /// **安定した識別子**（コマンドの型名、または `scan`）。
    ///
    /// 表示名ではない——言語で変わる文字列を絞り込みの鍵に使うと、表示言語を
    /// 切り替えた瞬間に過去の行が引けなくなる（`OperationLogKind.rawValue` を
    /// 生値で持つのと同じ判断）。
    public let commandName: String
    public let kind: OperationLogKind
    /// 対象の絶対パス [OH-01]。**空でありうる**——ラベルの改名のように
    /// ファイルを対象に取らない操作がある。
    public let targets: [String]
    /// 対象ライブラリの**外部識別子**。行 ID（`LibraryID`）は登録解除で
    /// 再利用されうるので使わない [通知履歴の `NotificationTarget` と同じ判断]。
    ///
    /// **走査の行にしか入らない** [2026-09 の実装範囲]。ファイル操作の
    /// コマンドは自分がどのライブラリの中で起きたかを知らず、そもそも
    /// ライブラリの外での操作もある。半分しか埋まらない列で絞り込みを
    /// 提供すると「絞ったのに出てこない」になるため、左ペインには出さない。
    public let libraryUUID: UUID?
    /// 一覧の「内容」列に出す 1 行 [OH-01]。
    ///
    /// **記録した時点の言語のまま残る。** コマンドの `displayName` は対象の
    /// 名前を埋め込んで組み立てられており、あとから作り直せない——そして
    /// 「そのとき何をしたか」の記録としては、当時の文言のまま残るほうが正しい。
    public let summary: String
    /// 行を開いたときにだけ読む内訳 [OH-04]。件数・失敗理由・変換前後など。
    public let detail: String?
    /// 上限 [AppLimits.Operations.maxTargetsPerEntry] で切り落とした対象の件数。
    ///
    /// **文言はここで組み立てない**——ローカライズは UI 層の仕事で、
    /// `QooKit` は表示言語を知らない [A-01]。件数だけを渡す。
    public let truncatedTargets: Int

    public init(id: OperationLogID, date: Date, commandName: String,
                kind: OperationLogKind, targets: [String], libraryUUID: UUID?,
                summary: String, detail: String?, truncatedTargets: Int = 0) {
        self.id = id
        self.date = date
        self.commandName = commandName
        self.kind = kind
        self.targets = targets
        self.libraryUUID = libraryUUID
        self.summary = summary
        self.detail = detail
        self.truncatedTargets = truncatedTargets
    }

    /// 一覧の「対象」列 [OH-01]。**1 件ならファイル名、複数なら件数**
    /// ——絶対パスをそのまま並べると列が読めない。全体は詳細で見る。
    public func targetsDisplayName(pluralized: (Int) -> String) -> String {
        switch targets.count {
        case 0: ""
        case 1: (targets[0] as NSString).lastPathComponent
        default: pluralized(targets.count)
        }
    }
}

/// 書き込む側の値（行 ID をまだ持たない）。
public struct OperationLogDraft: Sendable, Hashable {
    public var date: Date
    public var commandName: String
    public var kind: OperationLogKind
    public var targets: [String]
    public var libraryUUID: UUID?
    public var summary: String
    public var detail: String?

    public init(date: Date = Date(), commandName: String, kind: OperationLogKind,
                targets: [String] = [], libraryUUID: UUID? = nil,
                summary: String, detail: String? = nil) {
        self.date = date
        self.commandName = commandName
        self.kind = kind
        self.targets = targets
        self.libraryUUID = libraryUUID
        self.summary = summary
        self.detail = detail
    }
}

/// 一覧の絞り込み [OH-02]。
public struct OperationLogFilter: Sendable, Equatable {
    public var group: OperationLogGroup?
    public var period: DateInterval?
    public var keyword: String?

    public init(group: OperationLogGroup? = nil, period: DateInterval? = nil,
                keyword: String? = nil) {
        self.group = group
        self.period = period
        self.keyword = keyword
    }
}

/// 操作履歴ストア [15章 §15.13]。
///
/// **ライブラリ単位ではなくアプリ単位**——`operationLog` は `library` への
/// 外部キーを持たない。ライブラリを登録解除しても、そこで行った操作の記録は
/// 残る（残っていなければ「なぜ消えたのか」を後から辿れない。通知履歴と
/// まったく同じ判断）。
public protocol OperationLogStore: Sendable {
    @discardableResult
    func append(_ draft: OperationLogDraft) async throws -> OperationLogID
    /// 日時の降順。**上限は `purgeExpired` が保つ**ので件数の上限引数は取らない。
    func query(_ filter: OperationLogFilter) async throws -> [OperationLogEntry]
    func count() async throws -> Int
    /// 保持期間と件数の上限を保つ [HS-04]。**期限切れと上限超過の両方**を落とす。
    func purgeExpired(retentionDays: Int, maxCount: Int) async throws
}

/// CSV への書き出し [OH-02]。書式は `CSVDocument` が持つ。
public enum OperationLogCSV {
    /// - Parameter truncationNote: 上限で切り落とした件数を述べる文
    ///   [AppLimits.Operations.maxTargetsPerEntry]。**UI が組み立てる**
    ///   （`QooKit` は表示言語を知らない [A-01]）。
    public static func encode(_ rows: [OperationLogEntry],
                              header: [String],
                              kindName: (OperationLogKind) -> String,
                              dateFormatter: (Date) -> String,
                              truncationNote: (Int) -> String) -> Data {
        CSVDocument.encode(header: header, rows: rows.map { row in
            // **切り落としを書き出しにも出す**［レビューで発見］。画面には
            // 「ほか N 件」が出るのに CSV に無いと、**残った 50 件が全件の
            // ように読める**——棚卸しに使う書き出しでそれは危うい。
            var detail = row.detail ?? ""
            if row.truncatedTargets > 0 {
                let note = truncationNote(row.truncatedTargets)
                detail = detail.isEmpty ? note : detail + "\n" + note
            }
            return [
                dateFormatter(row.date),
                kindName(row.kind),
                row.summary,
                // **CSV には対象を全部書く**——画面の列は読みやすさのために
                // 畳むが、書き出しは棚卸しに使うものなので省略しない。
                row.targets.joined(separator: "\n"),
                detail,
            ]
        })
    }
}
