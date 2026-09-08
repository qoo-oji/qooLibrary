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
    /// 連鎖でラベル・評価・手動タイトルをすべて消す。
    ///
    /// **「データを残す」を選んだ登録解除 [RG4-01] では取らない**——行を 1 つも
    /// 消さないので破壊的でなく、控えを取る意味が無い。
    case libraryDelete
    /// バックアップから復元する直前 [BK-03]。
    ///
    /// **復元そのものが破壊的**なので、戻す前の状態も 1 世代残す
    /// ——「戻したら戻しすぎた」を取り返せなくてはならない。
    case beforeRestore
}

extension BackupReason {
    /// この契機で**何を写すか** [BK-03][BK-06][IE-16]。
    ///
    /// **DB 全体に及ぶ操作の直前と、起動時は一式**［設計判断、2026-09-05］。
    /// ストア複製は 10 万件で 71 MB ある［Spikes T-03 実測］ので、そのライブラリの
    /// 中に閉じる操作（ラベルの一括削除・テンプレートの適用）の直前まで
    /// 取ると、**3 世代が小さな操作で埋まって「丸ごと戻したい」場面に
    /// 残らない**——そちらは JSON が持つ範囲（手動ラベル・保護された基本
    /// 情報・設定）で足りる。同じ理由で ``BackupGeneration/Kind/appData`` も
    /// 外す——それらの操作はブックマークにもカバーの複製にも触れない。
    ///
    /// **``BackupGeneration/Kind/store`` と ``BackupGeneration/Kind/appData``
    /// は必ず対で取る** [BK-06]。`library.uuid` は登録フォルダ ID そのものなので、
    /// DB とブックマークは**対でしか意味を持たない**——片方だけ残る世代を作ると、
    /// そこから復元しても「ライブラリの行はあるが実体に到達できない」状態になる。
    ///
    /// **``BackupReason/beforeRestore`` だけは
    /// ``BackupGeneration/Kind/document`` を取らない**［2026-09-07］。
    /// 退避を作る `BackupStore.swapInStore` は `QooDatabase.open` の**前**に
    /// 走るので、JSON を書くのに要るリポジトリがまだ無い——**構造的に
    /// 書けない**。
    ///
    /// > 2026-09-07 までここが 3 種を返していたが、実装は `store` しか
    /// > 作っていなかった。**宣言と実装が食い違うと、その差はいちばん
    /// > 気づきにくい形で出る**——「戻しすぎた」から退避へ戻したときに
    /// > `restoreAppData` が対の束を見つけられず、DB は退避した時点・
    /// > `registeredFolders.json` は 1 回目の復元で書き戻された時点、で
    /// > 食い違った。BK3-11 が塞ごうとした穴と同じ形である。
    ///
    /// `switch` を網羅的に書いてあるので、契機を足す人は必ず何を取るか選ぶ。
    public var kinds: Set<BackupGeneration.Kind> {
        switch self {
        case .launch, .schemaMigration, .jsonImport, .libraryDelete:
            [.document, .store, .appData]
        case .beforeRestore:
            [.store, .appData]
        case .bulkLabelDelete, .templateApply:
            [.document]
        }
    }
}

/// 自動バックアップの設定 [BK-01]［ユーザー要望: ON/OFF と頻度の決定権を持つ］。
///
/// ## 3 つとも既定は OFF［ユーザー判断、v2.17］
///
/// **この機能を必要とする利用者は、すでに Time Machine を使っている可能性が
/// 高い**——OS の仕組みが同じことをより広く（アプリのコンテナごと、1 時間ごとに）
/// やっているのに、アプリが独自に世代を溜めると**気づかないうちに容量を使う**。
/// 必要な人が明示的に ON にする形にした。
///
/// OFF でも失われるものは無い: `backups/` に何も書かないだけで、DB も
/// `usercovers/` も通常どおり動く。ON にすれば次の契機から溜まり始める。
///
/// ## 3 つに分けてある
///
/// 契機ごとに「利用者が止めてよいか」の性質が違う。
///
/// | 設定 | 効く契機 | なぜ分けるか |
/// |---|---|---|
/// | ``LaunchInterval`` | 起動時 [BK-01] | 日常的に溜まるのはここだけ。頻度に「取らない」を含めるので、ON/OFF を別に持たなくてよい |
/// | `beforeDestructive` | 破壊的操作の直前 [BK-02] | 利用者の操作に紐づく。止めれば「⌘Z で戻せない操作」の戻り道が消えるが、それは利用者の判断 |
/// | `beforeMigration` | スキーマ移行の直前 [MG-10] | **利用者の操作ではなくアプリの更新で起きる**。R-14（致命的）への直接の備えなので、他と同じトグルに混ぜない［ユーザー判断、v2.17］ |
public enum BackupSettings {
    /// 起動時に控えを取る頻度 [BK-01]。
    ///
    /// **「取らない」を選択肢に含める**——ON/OFF と頻度を別々の設定にすると、
    /// 「OFF なのに頻度が選べる」という意味の無い組み合わせができる。
    public enum LaunchInterval: String, Sendable, CaseIterable, Codable {
        /// 起動のたび。
        case everyLaunch
        /// 1 日 1 回（既定）。
        case daily
        /// 1 週間に 1 回。
        case weekly
        /// 取らない。**破壊的操作の直前 [BK-02] と移行前 [MG-10] は別の設定**なので、
        /// これを選んでもそちらは止まらない。
        case never

        /// **既定は「取らない」**［ユーザー判断、v2.17］。理由は ``BackupSettings`` の
        /// 型コメント（Time Machine と二重に溜めない）。
        public static let `default` = LaunchInterval.never

        /// 前回からこれだけ空いていれば取る。`never` は `nil`。
        public var seconds: TimeInterval? {
            switch self {
            case .everyLaunch: 0
            case .daily: 24 * 60 * 60
            case .weekly: 7 * 24 * 60 * 60
            case .never: nil
            }
        }
    }

    public enum PreferenceKeys {
        public static let launchInterval = "qoo.backup.launchInterval"
        public static let beforeDestructive = "qoo.backup.beforeDestructive"
        public static let beforeMigration = "qoo.backup.beforeMigration"
    }

    /// 破壊的操作の直前に取るか [BK-02]。**既定は取らない。**
    public static let defaultBeforeDestructive = false
    /// スキーマ移行の直前に取るか [MG-10]。**既定は取らない。**
    ///
    /// 要件 MG-10 は当初「必ず作成する」と書いていたが、v2.17 で
    /// 「既定は取らない。設定で ON にできる」へ改めた［ユーザー判断］。
    public static let defaultBeforeMigration = false
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
        /// **DB の外にある、再生成できないデータ一式** [BK-06]（v2.17 で追加）。
        ///
        /// 中身は ``AppDataArchive``（JSON 1 ファイル、数 KB）。登録フォルダと
        /// Security-Scoped Bookmark・ボリューム許可・アプリの関連付けを収める。
        ///
        /// **カバーの複製は入らない**——共有プールへハードリンクし、ここには
        /// 参照の一覧だけを持つ（``AppDataBundle/userCoverPool``）。束を
        /// 書庫にしないのはそのため: 中身が数 KB になったので圧縮する意味が無く、
        /// 書き込みが同期のまま済む（移行前フック [MG-10] は同期である）。
        ///
        /// **``store`` と対で意味を持つ**——`library.uuid` は登録フォルダ ID
        /// そのものなので、DB だけ戻してもブックマークが古ければライブラリは
        /// 実体に到達できない。IE-16 の「1 操作で完全に戻せる」は、v2.17 まで
        /// **このファイルが無事であることを暗黙の前提にしていた**。
        case appData

        /// ファイル名の拡張子。
        public var filenameExtension: String {
            switch self {
            case .document: "json"
            case .store: "sqlite"
            case .appData: "appdata"
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

/// `appData` の束に入れるものの綴り [BK-06]。
///
/// 束の実体は **JSON 1 ファイル**（``AppDataArchive``、拡張子 `.appdata`）。
/// 中身が数 KB なので書庫にしていない [BK3-13]。
///
/// **書く側と読む側で 1 箇所にする**——`BackupFileName` と同じ理由で、
/// ここがずれると書いたものを自分で読み戻せない。しかも壊れ方が静かで、
/// 「復元したのにブックマークが戻っていない」と気づくのは *次に起動して
/// ライブラリが消えて見えたとき* になる。
///
/// ## 何を入れ、何を入れないか [BK-06]
///
/// | 入れる | なぜ |
/// |---|---|
/// | `registeredFolders.json` | Security-Scoped Bookmark。**環境固有で作り直せない**（利用者がフォルダを選び直すしかない）。`library.uuid` はこの登録の ID そのものなので、DB と対でしか意味を持たない |
/// | `volumeAccess.json` | 同上。失うとボリュームへ到達できなくなる |
/// | `usercovers/` | 元画像は消えている前提 [CV-08]。**アプリ自身が消す経路**（起動時の掃除・ライブラリの削除）を持つ |
/// | `appAssociations.json` | 再設定はできるが手間。小さいので入れる |
///
/// サムネイルキャッシュ・Quick Look の一時複製・診断ログは**入れない**
/// ——いずれも再生成できる [MG-21] か、戻す意味が無い。
public enum AppDataBundle {
    public static let registeredFolders = "registeredFolders.json"
    public static let volumeAccess = "volumeAccess.json"
    public static let appAssociations = "appAssociations.json"

    /// カバーの複製を溜める**共有プール**の名前（束の中ではなく `backups/` の直下）。
    ///
    /// ## 束に入れず、ハードリンクで共有する［ユーザー要望: 肥大化を防ぐ］
    ///
    /// カバーの複製は**保存のたびに新しい UUID を振る**（`UserCoverStore`）ので
    /// **一度書かれたら中身が変わらない**。この不変性のおかげで、世代ごとに
    /// 中身を写す必要がまったく無い——`backups/usercovers/<libraryUUID>/<ref>`
    /// へハードリンクを張れば、**実占有は 1 つ分のまま**で全世代から参照できる
    /// ［実測: 同一ボリューム内で inode を共有し、`du` は 1 つ分。元を消しても
    /// リンク先の中身は無事］。
    ///
    /// 世代ごとに中身を写す素朴な造りだと、カバーを多く差し替えた利用者で
    /// **世代数倍に膨らむ**（1 万冊を全部差し替えれば数 GB × 世代数）。
    /// しかも画像は既に圧縮済みなので、書庫に入れても縮まない。
    ///
    /// 実際に容量を食うのは「利用者が差し替えて `usercovers/` からは消えたが、
    /// まだどれかの世代が参照しているもの」だけで、その世代が剪定されれば
    /// 一緒に消える（``BackupStore`` のゴミ集め）。
    public static let userCoverPool = "usercovers"

    /// 復元で**置き換える**もの [BK-06]。
    ///
    /// DB と整合していなければ意味を持たない——古いブックマークと新しい DB が
    /// 混ざると、行はあるのに到達できないライブラリができる。
    public static let replacedFiles = [registeredFolders, volumeAccess, appAssociations]

    /// 記述子。**常に入れる**［外部調査への答え］。
    ///
    /// 3 つの役目を 1 つで果たす。
    ///
    /// 1. **この束が qooLibrary の `appData` であることの判定。** 外部調査で
    ///    出た既知の不具合（Confluence の `exportDescriptor.properties` 欠落で
    ///    復元が失敗する）への答え。
    /// 2. **「入っていない」と「その時点で 0 件だった」の区別。** 登録が 1 件も
    ///    無い状態も状態であり、復元でそこへ戻せなければ対の意味が崩れる。
    ///    一覧を持てば、書き漏らしと空を取り違えない。
    /// 3. **中身が空の束を書く分岐が生じない。** 記述子が常にあるので、
    ///    「1 つも入っていない束をどう扱うか」を考えずに済む。
    public static let manifest = "manifest.json"
}

/// `appData` の束に入る記述子 [BK-06]。
public struct AppDataManifest: Codable, Sendable, Equatable {
    /// この束の形式の版。**中身の綴りを変えたら上げる。**
    ///
    /// 読む側は `<=` で判定する [IE-14 と同じ規則]——アプリより新しい束は
    /// 「読めない」と正しく断り、黙って一部だけ復元しない。
    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date
    /// 実際に入っているファイル（``AppDataBundle/replacedFiles`` のうち、
    /// 取った時点で存在したもの）。
    public var files: [String]
    /// この世代が参照しているカバーの複製 [BK-06]。
    ///
    /// **実体は束の中ではなく共有プール**（``AppDataBundle/userCoverPool``）に
    /// ある。ここが持つのは「どれを参照しているか」だけで、
    ///
    /// - **復元**は、この一覧を見てプールから `usercovers/` へ戻す。
    /// - **剪定**は、全世代のこの一覧を集めて、どこからも参照されない実体を消す。
    ///
    /// 鍵はライブラリ UUID の文字列、値はその配下の複製の名前（`<uuid>.<ext>`）。
    public var userCovers: [String: [String]]

    /// 参照している複製の総数。表示と照合に使う。
    public var userCoverCount: Int { userCovers.values.reduce(0) { $0 + $1.count } }

    /// 写せなかった複製の件数。**0 でないことは「守れていない」の印**
    /// ——ハードリンクを作れない環境（ファイルシステムが非対応）で起きる。
    /// 黙って複製へ落とすと肥大化を招くので、**含めずに数だけ残す**。
    public var userCoversSkipped: Int

    /// 在るのに**読めなかった**設定ファイルの件数。
    ///
    /// `files` に載らないことは「その時点で無かった」を意味する [BK3-14] ので、
    /// 読めなかったものを同じ扱いにすると**束が静かに欠けたまま成功として
    /// 書かれる**［code-review で発見］。`userCoversSkipped` と同じく、
    /// 0 でないことが「守れていない」の印。
    ///
    /// **Optional にしてある**——この鍵を持たない束（v2.17 の最初の実装が
    /// 書いたもの）を読めなくしないため [IE-14 と同じ配慮]。
    public var filesUnreadable: Int?

    public init(version: Int = AppDataManifest.currentVersion,
                createdAt: Date = Date(),
                files: [String],
                userCovers: [String: [String]] = [:],
                userCoversSkipped: Int = 0,
                filesUnreadable: Int = 0)
    {
        self.version = version
        self.createdAt = createdAt
        self.files = files
        self.userCovers = userCovers
        self.userCoversSkipped = userCoversSkipped
        self.filesUnreadable = filesUnreadable
    }
}

/// `appData` の中身 [BK-06]。
///
/// **ファイルの中身は解釈しない。** そのときのバイト列をそのまま戻すのが
/// バックアップの仕事で、形式を理解しようとすると*その形式が変わった日*に
/// 読めなくなる——守ろうとしている当のもの（形式変更で壊れること）に
/// 自分で当たることになる。
public struct AppDataArchive: Codable, Sendable, Equatable {
    public var manifest: AppDataManifest
    /// ファイル名（``AppDataBundle`` の綴り）→ そのときのバイト列。
    ///
    /// `JSONEncoder` は `Data` を base64 で書くので、中身が何であっても壊れない。
    public var files: [String: Data]

    public init(manifest: AppDataManifest, files: [String: Data]) {
        self.manifest = manifest
        self.files = files
    }
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

/// 「次の起動で復元する」という予約 [BK-03][IE-16]。
///
/// ## なぜ印を置いて再起動を挟むのか［ユーザー判断、2026-09-06］
///
/// 復元は**動いているアプリの中では行わない**。印を `backups/` へ置いて
/// 終了し、**次の起動で `QooDatabase.open` の前に**差し替える。
///
/// | 得られること | 理由 |
/// |---|---|
/// | **DB を開けなかった起動からも同じ経路で戻せる** [RB-03][RB-06] | 差し替えが `open` より前にあるので、直前の起動でストアが開けたかどうかに一切依存しない。ライブ復元だと接続が無い場面で使えず、**同じ機能に経路が 2 本**できる（このリポジトリが繰り返し取り残してきた形）|
/// | Undo スタック・開いているウインドウ・リポジトリの食い違いが**構造的に起きない** | 差し替えの時点でそれらがまだ存在しない。ライブ復元だと行 ID を握ったままの画面が残る |
/// | 自分のプロセスが DB を掴んだまま差し替える危険が無い | ［外部調査: 掴まれていると復元が失敗し、しかも「破損」と誤報告される］|
///
/// **自動で再起動はしない**［設計判断］。`createsNewApplicationInstance` で
/// 新しいインスタンスを先に起こすと、**古いインスタンスがまだストアを
/// 掴んでいる間に新しいほうが差し替えにかかる**——避けたかった当の状況を
/// 自分で作ることになる。印を書いたら**すぐ終了する**（それ以上の変更を
/// 失わせないため）ことだけを守り、起動し直すのは利用者に委ねる。
public struct PendingRestore: Codable, Sendable, Equatable {
    /// 戻す世代のファイル名。**URL ではなく名前**——`backups/` の場所は
    /// `BackupStore` が決めるので、印が絶対パスを持つと置き場所が 2 箇所に
    /// なる（App Support の場所は環境で変わりうる）。
    public var fileName: String
    public var requestedAt: Date

    public init(fileName: String, requestedAt: Date = Date()) {
        self.fileName = fileName
        self.requestedAt = requestedAt
    }

    /// 印そのもののファイル名。**先頭がドットで拡張子が `json`** なので
    /// `BackupFileName.parse` は解釈できず、世代として数えられない
    /// ——数えられると剪定がこれを消しにかかる。
    public static let fileName = ".pending-restore.json"
}

/// 復元の結果 [BK-03]。起動時に 1 度だけ報告する。
public struct RestoreOutcome: Sendable, Equatable {
    public enum Failure: Sendable, Equatable {
        /// 印はあったが、その世代が既に無い（利用者が消した・剪定された）。
        case generationMissing(String)
        /// 複製が壊れている [RB-03]。**差し替えない。**
        case sourceCorrupt(String)
        /// 複製のほうがアプリより新しい [MG-12]。**差し替えない**
        /// ——戻した瞬間に `schemaTooNew` で起動できなくなる。
        case sourceTooNew(String)
        /// 差し替えそのものに失敗した。**元のストアは巻き戻してある。**
        case swapFailed(String)
    }

    public var restoredFrom: String
    /// 差し替え前のストアを退避した先。**これが「戻しすぎた」の戻り道**。
    public var previousStoreURL: URL?
    public var failure: Failure?

    /// DB の外にあるデータ [BK-06] も戻したか。
    ///
    /// **偽のとき、DB は戻っているがブックマークは現在のまま**——古い版が
    /// 作った世代（束を持たない）か、書き戻しに失敗したか。`library.uuid` は
    /// 登録フォルダ ID そのものなので、**戻した DB のライブラリが現在の登録に
    /// 無ければ、その行は実体へ到達できない**。利用者に伝える必要がある。
    public var appDataRestored: Bool = false

    public init(restoredFrom: String, previousStoreURL: URL? = nil,
                failure: Failure? = nil, appDataRestored: Bool = false) {
        self.restoredFrom = restoredFrom
        self.previousStoreURL = previousStoreURL
        self.failure = failure
        self.appDataRestored = appDataRestored
    }

    public var succeeded: Bool { failure == nil }
}
