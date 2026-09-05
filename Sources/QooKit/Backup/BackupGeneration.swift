//
//  自動バックアップの世代 [BK-01〜BK-05][MG-10]。
//
//  置き場所と剪定は `BackupStore`（`QooInfrastructure`）、契機の配線は
//  `BackupService`（`QooApplication`）。ここは**綴りと分類だけ**を持つ。
//
import Foundation

/// スナップショットを取った理由 [BK-01][BK-02][MG-10]。
///
/// 仕様書 07章 §7.6 の `DestructiveReason` を畳んだもの。**1 つの列挙にする**
/// ——起動時 [BK-01] と破壊的操作の前 [BK-02] は取る契機が違うだけで、
/// 置き場所も世代管理も剪定も同じなので、2 つの型に割ると同じ規則を
/// 2 通り書くことになる。
public enum BackupReason: String, Sendable, CaseIterable, Codable {
    /// 起動時 [BK-01]。`AppLimits.Backup.launchSnapshotInterval` を空けて取る。
    case launch
    /// スキーマ移行の直前 [BK-02][MG-10]。**JSON とストア複製の両方**を取る
    /// ——要件 MG-10 が名指しで両方を要求している唯一の契機で、R-14
    /// （移行の失敗でラベルや評価を失う）への直接の備えだから。
    case schemaMigration
    /// JSON の取り込みの直前 [BK-02][IE-12][JS-07]。
    case jsonImport
    /// ラベルの一括削除の直前 [BK-02]。
    case bulkLabelDelete
    /// テンプレートの適用・プリセット改訂の取り込みの直前 [BK-02][LT-14]。
    case templateApply
    /// ライブラリの削除の直前［ユーザー判断で BK-02 の対象に追加、2026-09-05］。
    ///
    /// **要件の一覧には無いが、実際にはこれが最も破壊的**——`deleteLibrary` は
    /// 連鎖でラベル・評価・手動タイトルをすべて消し、`keepLabels` を選べる
    /// 退避先はまだ無い [RG-06]。
    case libraryDelete
    /// バックアップから復元する直前 [BK-03]。
    ///
    /// **復元そのものが破壊的**なので、戻す前の状態も 1 世代残す
    /// ——「戻したら戻しすぎた」を取り返せなくてはならない。
    case beforeRestore
}

extension BackupReason {
    /// この契機で**ストア複製も**取るか [BK-03][IE-16]。
    ///
    /// **DB 全体に及ぶ操作の直前と、起動時だけ**［設計判断、2026-09-05］。
    /// 複製は 10 万件で 71 MB ある［Spikes T-03 実測］ので、そのライブラリの
    /// 中に閉じる操作（ラベルの一括削除・テンプレートの適用）の直前まで
    /// 取ると、**3 世代が小さな操作で埋まって「丸ごと戻したい」場面に
    /// 残らない**——そちらは JSON が持つ範囲（手動ラベル・保護された基本
    /// 情報・設定）で足りる。
    ///
    /// `switch` を網羅的に書いてあるので、契機を足す人は必ずどちらかを選ぶ。
    public var copiesStore: Bool {
        switch self {
        case .launch, .schemaMigration, .jsonImport, .beforeRestore, .libraryDelete:
            true
        case .bulkLabelDelete, .templateApply:
            false
        }
    }
}

/// 置いてあるスナップショット 1 件。
public struct BackupGeneration: Sendable, Equatable, Hashable, Identifiable {
    /// 何を写したか。**世代数を別々に数える** [AppLimits.Backup]。
    public enum Kind: String, Sendable, CaseIterable, Hashable {
        /// 再生成できないデータだけの JSON [BK-01][BK-05]。小さく、**版を
        /// またいで読める**（`schemaVersion` で判定する）。ただし
        /// ブックマークを持てないのでライブラリの行は戻せない [07章 §7.5]。
        case document
        /// SQLite ストアの丸ごとの複製 [BK-03]。
        ///
        /// **これがあると 1 操作で完全に戻せる** [IE-16]——Security-Scoped
        /// Bookmark は `registeredFolders.json` にあり **DB の外**で、
        /// `library.uuid` は登録フォルダ ID そのものなので、DB を戻せば
        /// ライブラリの行も生きた登録を指す。
        case store

        /// ファイル名の拡張子。
        public var filenameExtension: String {
            switch self {
            case .document: "json"
            case .store: "sqlite"
            }
        }
    }

    public var id: String { fileName }
    public var fileName: String
    public var date: Date
    public var reason: BackupReason
    public var kind: Kind
    public var byteCount: Int64
    public var url: URL

    public init(fileName: String, date: Date, reason: BackupReason,
                kind: Kind, byteCount: Int64, url: URL) {
        self.fileName = fileName
        self.date = date
        self.reason = reason
        self.kind = kind
        self.byteCount = byteCount
        self.url = url
    }
}

/// ファイル名の綴り。**書く側と読む側で 1 箇所にする。**
///
/// ここがずれると、書いたものを自分で列挙できなくなり——**剪定が効かずに
/// 世代が無限に増える**という、容量を食い潰すまで誰も気づかない壊れ方をする。
public enum BackupFileName {
    /// `20260905T142530123Z-launch.json`
    ///
    /// **ミリ秒まで入れる**——同じ秒に 2 回取る場面が実際にある
    /// （テンプレート適用の直後に取り込む、など）。秒までだと後の 1 件が
    /// 前の 1 件を上書きし、**世代が 1 つ静かに消える**。
    public static func make(date: Date, reason: BackupReason,
                            kind: BackupGeneration.Kind) -> String
    {
        "\(timestamp(date))-\(reason.rawValue).\(kind.filenameExtension)"
    }

    /// 解釈できない名前は `nil`。**利用者が置いた無関係なファイルを
    /// 世代として数えない**ため——数えると剪定がそれを消しにかかる。
    public static func parse(_ fileName: String) -> BackupFileParts? {
        let name = fileName as NSString
        let ext = name.pathExtension
        guard let kind = BackupGeneration.Kind.allCases
            .first(where: { $0.filenameExtension == ext }) else { return nil }
        let stem = name.deletingPathExtension
        guard let dash = stem.firstIndex(of: "-") else { return nil }
        guard let date = parseTimestamp(String(stem[stem.startIndex ..< dash])) else { return nil }
        let rest = String(stem[stem.index(after: dash)...])
        guard let reason = BackupReason(rawValue: rest) else { return nil }
        return BackupFileParts(date: date, reason: reason, kind: kind)
    }

    public struct BackupFileParts: Sendable, Equatable {
        public var date: Date
        public var reason: BackupReason
        public var kind: BackupGeneration.Kind
    }

    // UTC 固定・`en_US_POSIX`。**利用者のロケールと暦に依存させない**
    // ——和暦の環境で「R08…」のような名前を書くと、暦を切り替えた瞬間に
    // 自分の書いたファイルを読めなくなる。
    private static let format = "yyyyMMdd'T'HHmmssSSS'Z'"

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    public static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
    public static func parseTimestamp(_ text: String) -> Date? { formatter().date(from: text) }
}

/// 移行前の DB へ触れる窓口 [MG-10]。実装は `QooPersistence`。
///
/// **ポートに分けてあるのは、いちばん危ない経路を試せるようにするため**
/// ——移行前のストアは定義上「アプリが知らない古いスキーマ」なので、
/// 現行の record 型による書き出しは*失敗するのが普通*である。その状況で
/// 何が残るかは、実装型のままでは組み立てられない [A-02][RP2-01]。
public protocol PreMigrationSource: Sendable {
    /// 移行前の状態が存在するか。**新規ストアでは偽**（写すものが無い）。
    var hasExistingSchema: Bool { get }
    /// 再生成できないデータだけを JSON へ写す [BK-05]。
    func exportDocument(appVersion: String?) throws -> BackupDocument
    /// ストアを丸ごと複製する [BK-03]。**スキーマに依存しない。**
    func copyStore(to destination: URL) throws
    /// 移行前の DB が健全か [RB-03]。
    func integrityCheck() throws -> Bool
}
