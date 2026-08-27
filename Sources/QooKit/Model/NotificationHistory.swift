//
//  通知履歴 [NT-01〜NT-08][NW-01〜NW-08][02章 §2.4][15章 §15.11]。
//
//  **プロトコルと値型は `QooKit`、実体は `QooPersistence` の
//  `notificationRecord` テーブル** [07章 §7.3]。`NotificationRouter`
//  （`QooApplication`）が唯一の書き手で、通知を出すときに必ずここへ落とす
//  ——記録を機能ごとに散らさない [ER-01 の精神]。
//
//  ## 何を記録するか［ユーザー判断、2026-08］
//  **強度を問わずすべて記録し、未読に数えるのは強度 4 以上だけ。**
//  要件 NT-01 / CB-11 は「強度 4 以上を記録」と定めていたが、着手前に実測した
//  ところ **`.transient`(4) を使う呼び出しは 3 箇所、`.logOnly`(5) は 1 箇所
//  だけで、残り 70 箇所超はすべて `.sheet`(2)** だった——そのまま作ると履歴は
//  ほぼ常に空で、NW-01 の「エラー」区分は永久に 0 件になる（エラーは全部
//  シートのため）。
//
//  記録を全強度へ広げ、**未読バッジの意味（＝見逃されうるもの）は
//  強度 4 以上のまま保つ**ことで、両方を成立させている。シートを目の前で
//  閉じた直後にバッジが立つ雑音は起きない。
//
//  **判断を求めるシート（衝突・完全削除の確認・ロック項目）はここへ来ない**
//  ——あれらは `NotificationRouter` を通らない専用のシートで、そもそも
//  「通知」ではなく「対話」である。
//
import Foundation

/// 通知の対象 [NT-04]。
///
/// **行 ID ではなく、パスと名前を非正規化して持つ** [07章 §7.3]。対象は消えうるし、
/// 消えた後も履歴としての意味を保たなければならない——「見つからなくなった
/// ファイル」の通知が、そのファイルが消えたせいで読めなくなっては本末転倒である。
public struct NotificationTarget: Sendable, Hashable, Codable {
    /// ライブラリの**外部識別子** [07章 §7.3]。行 ID（`LibraryID`）は登録解除で
    /// 再利用されうるので使わない。左ペインの「対象ライブラリ」絞り込み [NW-01]
    /// はこれで引く。
    public var libraryUUID: UUID?
    public var libraryName: String?
    /// 対象の絶対パス。**診断ログと違い匿名化しない**——利用者が自分の蔵書を
    /// 見返すための記録で、外部へ渡すものではない [LG2-06 とは目的が違う]。
    public var path: String?
    /// ファイルでもライブラリでもない対象（「初回スキャン」「JSON の取り込み」等）。
    public var processName: String?

    public init(libraryUUID: UUID? = nil, libraryName: String? = nil,
                path: String? = nil, processName: String? = nil) {
        self.libraryUUID = libraryUUID
        self.libraryName = libraryName
        self.path = path
        self.processName = processName
    }

    public static func library(uuid: UUID, name: String) -> NotificationTarget {
        NotificationTarget(libraryUUID: uuid, libraryName: name)
    }

    /// 一覧の「対象」列に出す 1 行 [NW-02]。
    public var displayName: String {
        if let libraryName, !libraryName.isEmpty { return libraryName }
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return processName ?? ""
    }
}

/// 履歴の行から関連画面へ飛ぶ導線 [NT-05][NW-04]。
///
/// **`RecoveryAction` のうち `.openWindow` のものだけを写す。** `.retry` や
/// `.dismiss` はその場限りの操作で、後から履歴を開いて押しても意味を持たない
/// ——「再試行」は当時の文脈（どのファイルを、どの設定で）を失っている。
public struct NotificationLink: Sendable, Hashable, Codable {
    /// `RecoveryAction.id` と同じ文字列。開く側が `switch` して画面を決める。
    public let actionID: String
    public let title: String

    public init(actionID: String, title: String) {
        self.actionID = actionID
        self.title = title
    }
}

/// 履歴に残った通知 1 件。
///
/// **`NotificationItem`（提示用）とは別の型にしてある**——`isRead` は提示には
/// 関係が無く、逆に `actions` のうち履歴で意味を持つのは `.openWindow` だけ。
/// 同じ型に両方の関心を詰めると、どちらの文脈で読むべきか分からなくなる
/// （`FileSnapshot`（走査が観測したもの）と `FileRow`（DB の行）を分けているのと同じ）。
public struct StoredNotification: Sendable, Hashable, Identifiable {
    public let id: NotificationID
    public let date: Date
    public let category: NotificationItem.Category
    public let severity: NotificationSeverity
    public let target: NotificationTarget?
    public let title: String
    public let body: String
    public let technicalDetail: String?
    public let links: [NotificationLink]
    public var isRead: Bool

    public init(id: NotificationID, date: Date, category: NotificationItem.Category,
                severity: NotificationSeverity, target: NotificationTarget?,
                title: String, body: String, technicalDetail: String?,
                links: [NotificationLink], isRead: Bool) {
        self.id = id
        self.date = date
        self.category = category
        self.severity = severity
        self.target = target
        self.title = title
        self.body = body
        self.technicalDetail = technicalDetail
        self.links = links
        self.isRead = isRead
    }

    /// 未読に数える対象か [NT-02]。
    ///
    /// **強度 4 以上だけ**——強度 1〜3（アプリモーダル・シート・インライン）は
    /// その場で利用者が直接見ているので、バッジで「まだ見ていないものがある」
    /// と主張するのは嘘になる。バッジが常時立っていると、本当に見てほしい
    /// ときに読み飛ばされる（走査結果のダイアログで同じ判断をしている）。
    public static func countsAsUnread(severity: NotificationSeverity) -> Bool {
        severity >= .transient
    }

    /// 一覧で太字にするか [NW-03]。
    ///
    /// **バッジと同じ判定を使う**［レビューで発見］。`isRead` だけで太字に
    /// すると、記録は全強度なので**シートを目の前で閉じた行まで太字**になり、
    /// 一方「すべて既読にする」はバッジ（強度 4 以上）が 0 のとき無効になる
    /// ——画面が太字だらけなのにボタンが押せない、という食い違いが出る。
    public var isUnread: Bool {
        !isRead && Self.countsAsUnread(severity: severity)
    }
}

/// 一覧の絞り込み [NW-05][NW-01]。
public struct NotificationHistoryFilter: Sendable, Equatable {
    public var category: NotificationItem.Category?
    public var libraryUUID: UUID?
    public var period: DateInterval?
    public var keyword: String?

    public init(category: NotificationItem.Category? = nil, libraryUUID: UUID? = nil,
                period: DateInterval? = nil, keyword: String? = nil) {
        self.category = category
        self.libraryUUID = libraryUUID
        self.period = period
        self.keyword = keyword
    }
}

/// 通知履歴ストア [02章 §2.4]。
///
/// **ライブラリ単位ではなくアプリ単位**——`notificationRecord` は
/// `library` への外部キーを持たない。ライブラリを登録解除しても、その
/// ライブラリ宛の通知は履歴に残る（残っていなければ「なぜ消えたのか」を
/// 後から辿れない）。対象は `targetJSON` に非正規化して持つ。
public protocol NotificationHistoryStore: Sendable {
    @discardableResult
    func append(_ item: NotificationItem) async throws -> NotificationID
    /// 日時の降順。**上限は `purgeExpired` が保つ**ので件数の上限引数は取らない。
    func query(_ filter: NotificationHistoryFilter) async throws -> [StoredNotification]
    func unreadCount() async throws -> Int
    func markRead(_ ids: [NotificationID]) async throws                 // [NW-03]
    func markAllRead() async throws                                     // [NW-03]
    func delete(_ ids: [NotificationID]) async throws                   // [NW-06]
    func deleteAll() async throws                                       // [NW-06]
    /// 保持期間と件数の上限を保つ [NT-07]。**期限切れと上限超過の両方**を落とす。
    func purgeExpired(retentionDays: Int, maxCount: Int) async throws
}

/// CSV への書き出し [NW-07]。
///
/// **ストアではなく純粋関数にしてある**——書き出すのは「いま一覧に出ている
/// もの」であって DB 全件ではない（絞り込んでから書き出せないと、
/// 棚卸しの用途に使えない）。ストアに置くと絞り込みの条件をもう一度
/// 渡し直すことになり、一覧と食い違う余地が生まれる。
public enum NotificationCSV {
    /// RFC 4180。**先頭に BOM を付ける**——付けないと Excel が UTF-8 と
    /// 判定せず、日本語が化ける（利用者が最初に開くのはたいてい Excel か
    /// 「数値」である）。
    public static func encode(_ rows: [StoredNotification],
                              header: [String],
                              categoryName: (NotificationItem.Category) -> String,
                              dateFormatter: (Date) -> String) -> Data {
        var text = header.map(escape).joined(separator: ",") + "\r\n"
        for row in rows {
            let fields = [
                dateFormatter(row.date),
                categoryName(row.category),
                row.target?.displayName ?? "",
                row.title,
                row.body,
                row.technicalDetail ?? "",
            ]
            text += fields.map(escape).joined(separator: ",") + "\r\n"
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        return data
    }

    /// 引用符・カンマ・改行を含む値を囲む。**囲むと決めたら引用符は二重にする**
    /// （RFC 4180）。
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
