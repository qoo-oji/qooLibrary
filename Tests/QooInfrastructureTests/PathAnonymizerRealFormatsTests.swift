import Foundation
import Testing

@testable import QooInfrastructure

/// **コードベースに実在するログ行の書式**を、**実在し得るファイル名**で並べ、
/// 匿名化後にユーザー由来の名前が 1 つも残らないことを検証する [LG2-06]。
///
/// ## このテストが存在する理由
///
/// 1-15 の実装後、実機のログを匿名化してみて取りこぼしが **3 回**見つかった。
/// いずれも「部品単位のテストは通るのに、実際に出力される 1 行では漏れる」
/// 種類だった:
///
/// 1. `Command.displayName` 経由でファイル名が素通しだった。
/// 2. **空白**を含むパス（`/Volumes/PRO-G40/My Sample/…`）が途中までしか
///    匿名化されなかった。
/// 3. **括弧**で始まるファイル名（`(成年コミック) [98765架空社] …`——この分野
///    ではもっとも普通の書式）がまるごと素通しになった。区切り記号として
///    括弧を終端に加えた「修正」が原因の退行。
///
/// 3 は、それ以前の回帰テストが `作品タイトル.cbz` という**現実には存在しない
/// 綺麗な名前**を標本にしていたために検出できなかった。**標本は必ず、実際に
/// 扱うファイル名の形（括弧・角括弧・空白・和文の句読点・記号）にすること。**
///
/// macOS のファイル名には `/` と NUL 以外のあらゆる文字が入るため、区切り
/// 文字による推測では原理的に安全にならない。現在は `Log.path(_:)` が
/// 書き込み時に範囲を明示する方式に変えてある（`PathAnonymizer` のコメント
/// 参照）。このテストはその前提が崩れていないことを守る。
///
/// **計装を追加・変更したら、その書式をここへ追加すること。**
@Suite struct PathAnonymizerRealFormatsTests {
    private let anonymizer = PathAnonymizer(salt: "test-salt")

    /// 実際に扱うファイル名の形。記号・括弧・空白・和文の句読点を含む。
    private static let volume = "/Volumes/PRO-G40"
    private static let library = "\(volume)/My Sample/成年コミック"
    private static let file = "\(library)/(成年コミック) [98765架空社] サンプルプレビュー.cbz"
    private static let folder = "\(library)/(成年コミック) [98765架空社] サンプルプレビュー"
    /// 区切りとして使っている記号や、パーサ泣かせの文字を名前に含めた例。
    ///
    /// `:` は POSIX 層ではファイル名に使える（Finder で `/` を入力すると
    /// この文字として保存される）。逆に `/` だけは成分の区切りなので入らない。
    private static let awkward = "\(library)/【C99】作品名 → 続編、その2「完全版」 (1:2).cbz"

    // MARK: ネットワーク上の標本 [NV-99]
    //
    // ネットワークではパスにサーバ名・共有名・**ユーザー名**が混じる。
    // マウントポイント（`/Volumes/<共有名>`）は通常のパスと同じ形だが、
    // `//user@host/share` の形（`statfs` の `f_mntfromname`、Foundation の
    // エラー文言）が説明文へ混じることがある。
    private static let share = "/Volumes/秘密の書庫"
    private static let networkFile = "\(share)/成年コミック/(成年コミック) [98765架空社] サンプルプレビュー.cbz"
    private static let mountSource = "//KosukeNishimura@TS-664._smb._tcp.local/秘密の書庫"

    /// 匿名化後のログに現れてはいけない断片。
    private static let secrets = [
        "PRO-G40", "My Sample", "成年コミック", "98765架空社", "サンプルプレビュー",
        "C99", "完全版", "続編", "マイライブラリ", "作品名",
        // ネットワーク由来 [NV-99]。**サーバ名・共有名・ユーザー名**も
        // ユーザーを指す情報なので、パス成分と同じく残してはならない。
        "秘密の書庫", "KosukeNishimura", "TS-664",
    ]

    /// 実在する計装の書式（`Sources/` の各 `Log.*` 呼び出しに対応）。
    private static func lines() -> [String] {
        [
            // FileOperationService
            "createDirectory: \(Log.path(folder))",
            "rename: \(Log.path(file)) → \(Log.path(awkward))",
            "move 完了: 2/2 件 → \(Log.path(library))",
            "copy: \(Log.path(file)) → \(Log.path(folder))",
            "trash 完了: 1/1 件",
            "trash に失敗: \(Log.path(file)) — 失敗しました",
            "deletePermanently: 項目が見つかりません \(Log.path(file))",
            "deletePermanently: ロック済みのためスキップ \(Log.path(awkward))",
            "deletePermanently 完了: 削除 1 件 / 失敗 1 件 / スキップ 0 件",
            "setLocked(true) 完了: 1/1 件",
            "createAlias: \(Log.path(file)) → \(Log.path(library))",
            "move が 3 件成功後に失敗: \(Log.path(file)) → \(Log.path(folder)) — 失敗",
            "promoteFromStaging: \(Log.path("/Users/me/Library/Containers/com.qoolibrary.app/Data/Library/Application Support/qooLibrary/staging/20ac63d7/f39e9baf.jpg")) → \(Log.path("\(folder)/189.jpg"))",
            // Archive
            "展開開始（zip / 201 エントリ / エンコーディング Unicode（UTF-8））: \(Log.path(file)) → \(Log.path(folder))",
            "展開完了（201 件 / 289690306 バイト / 拒否 0 件 / 改名 0 件）: \(Log.path(file))",
            "圧縮開始（zip / 暗号化 none）: 47 件 → \(Log.path("\(folder)/(成年コミック) [98765架空社] サンプルプレビュー.zip"))",
            "圧縮完了: \(Log.path("\(folder)/(成年コミック) [98765架空社] サンプルプレビュー.zip"))",
            "展開時にエントリを拒否（parentTraversal）: \(Log.redactable("【C99】作品名/../evil.txt"))",
            // Sandbox
            "登録フォルダのアクセスを開始: \(Log.path(library))",
            "登録フォルダのブックマークを解決できません: \(Log.redactable("マイライブラリ")) (library)",
            "登録フォルダを読み込みました: ライブラリ 5 件 / テンポラリ 1 件 / アクセス開始 6 件",
            // Command（`logDescription` 経由）
            "実行: extract: \(Log.path(file)) → \(Log.path(folder))",
            "取り消し: composite[createFolder: \(Log.path(folder)) | move: \(Log.path(file)) → \(Log.path(folder))]",
            "実行: compress(zip/none): \(Log.path(file)), \(Log.path(awkward)) ほか 42 件 → \(Log.path(folder))",
            "実行に失敗: move: \(Log.path(file)) → \(Log.path(folder)) — 失敗しました",
            // NotificationRouter / 自由文（引用符の安全網が拾う）
            "[強度2] 操作に失敗: 「(成年コミック) [98765架空社] サンプルプレビュー.cbz」という名前の項目はすでに存在します。",
            "[強度2] 移動に失敗: \u{201C}【C99】作品名 → 続編.cbz\u{201D} couldn\u{2019}t be moved.",
            // Image
            "サムネイルを生成できません（archive）: \(Log.path(file))",
            "サムネイルのキャッシュ保存に失敗: \(Log.path(awkward)) — 失敗",
            // ネットワーク [NV-99]
            "copy: \(Log.path(networkFile)) → \(Log.path(folder))",
            "move 完了: 12/12 件 → \(Log.path(share))",
            "登録フォルダのアクセスを開始: \(Log.path(share))",
            "ゴミ箱を持たない場所と判定: \(Log.path(networkFile)) — 失敗しました",
            // マウント元はパスではないが、失敗の説明文に混じり得る。
            "マウント元: \(Log.redactable(mountSource))",
        ]
    }

    @Test func noRealLogFormatLeaksAUserSuppliedName() {
        for line in Self.lines() {
            let anonymized = anonymizer.anonymize(line)
            for secret in Self.secrets {
                #expect(!anonymized.contains(secret), "「\(secret)」が残っています → \(anonymized)")
            }
        }
    }

    /// **この suite が空振りでないことの担保。**
    ///
    /// 標本の中にユーザー由来の断片が実際に含まれていなければ、
    /// `noRealLogFormatLeaksAUserSuppliedName` は何も検査していないのと
    /// 同じになる（1-16b で、そうと気づかずに空振りのテストを 1 つ書いた）。
    /// 匿名化する**前**の行には、すべての秘密が現れていなければならない。
    @Test func everySecretActuallyAppearsInTheSamples() {
        let raw = Self.lines().joined(separator: "\n")
        for secret in Self.secrets {
            #expect(raw.contains(secret), "「\(secret)」を含む標本が無い＝この秘密は検査されていない")
        }
    }

    @Test func markersAreRemovedFromTheAnonymizedOutput() {
        // 印はログを機械的に処理するための目印。読む人には見えてはならない。
        for line in Self.lines() {
            let anonymized = anonymizer.anonymize(line)
            #expect(!anonymized.contains(PathAnonymizer.pathOpen))
            #expect(!anonymized.contains(PathAnonymizer.pathClose))
            #expect(!anonymized.contains(PathAnonymizer.redactionOpen))
            #expect(!anonymized.contains(PathAnonymizer.redactionClose))
        }
    }

    @Test func markersAreRemovedWhenNotAnonymizing() {
        // 匿名化しない書き出しでも印は取り除き、元のパスがそのまま読めること。
        let line = "createDirectory: \(Log.path(Self.folder))"
        #expect(PathAnonymizer.strippingMarkers(line) == "createDirectory: \(Self.folder)")
    }

    @Test func filenamesFullOfPunctuationAreStillAnonymizedWholly() {
        // 括弧・角括弧・矢印・読点・鉤括弧・スラッシュ入りの丸括弧を全部含む名前。
        let line = "createDirectory: \(Log.path(Self.awkward))"
        let anonymized = anonymizer.anonymize(line)
        let path = anonymized.replacingOccurrences(of: "createDirectory: ", with: "")
        let components = path.split(separator: "/").map(String.init)
        // /Volumes/<PRO-G40>/<My Sample>/<成年コミック>/<名前>.cbz
        #expect(components.count == 5)
        #expect(components.first == "Volumes")
        #expect(components.dropFirst().dropLast().allSatisfy { $0.count == 8 && $0.allSatisfy(\.isHexDigit) })
        #expect(components.last?.hasSuffix(".cbz") == true)
    }

    @Test func aFilenameContainingTheMarkerItselfIsStillHandled() {
        // ファイル名に印そのもの（⟪ ⟫）が含まれていても、書き込み時の
        // 二重化で曖昧さが残らないこと。macOS のファイル名には `/` と NUL 以外の
        // あらゆる文字が入る、という前提の確認。
        let nasty = "\(Self.library)/⟪奇妙⟫な⟪名前⟫.cbz"
        let line = "createDirectory: \(Log.path(nasty)) — 完了"
        #expect(PathAnonymizer.strippingMarkers(line) == "createDirectory: \(nasty) — 完了")

        let anonymized = anonymizer.anonymize(line)
        #expect(!anonymized.contains("奇妙"))
        #expect(!anonymized.contains("名前"))
        #expect(anonymized.hasSuffix(" — 完了")) // 印の外はそのまま
    }

    @Test func aFilenameContainingTabsAndQuotesIsStillHandled() {
        // タブ・引用符・縦棒もファイル名としては合法。
        let nasty = "\(Self.library)/tab\tquote\"pipe|arrow→.cbz"
        let line = "createDirectory: \(Log.path(nasty))"
        let anonymized = anonymizer.anonymize(line)
        #expect(!anonymized.contains("quote"))
        #expect(!anonymized.contains("pipe"))
        #expect(!anonymized.contains("arrow"))
        #expect(!anonymized.contains("\t"))
    }

    @Test func enumerationsWithSlashesAreNotMistakenForPaths() {
        let line = "deletePermanently 完了: 削除 1 件 / 失敗 1 件 / スキップ 0 件"
        #expect(anonymizer.anonymize(line) == line)
    }

    @Test func separatorsAndSurroundingProseSurviveIntact() {
        let line = "move 完了: 2/2 件 → \(Log.path(Self.library))"
        let anonymized = anonymizer.anonymize(line)
        #expect(anonymized.hasPrefix("move 完了: 2/2 件 → /Volumes/"))
    }

    @Test func commaSeparatedPathListsAreEachAnonymized() {
        let line = "compress: \(Log.path(Self.file)), \(Log.path(Self.awkward)) → \(Log.path(Self.folder))"
        let anonymized = anonymizer.anonymize(line)
        for secret in Self.secrets {
            #expect(!anonymized.contains(secret))
        }
        #expect(anonymized.contains(", "))
        #expect(anonymized.contains(" → "))
        #expect(anonymized.contains(".cbz"))
    }

    @Test func unmarkedPathsInForeignTextAreStillCaught() {
        // `Foundation` の `localizedDescription` のように、こちらで書式を
        // 決められないテキストに現れる素のパス（推測の出番）。
        let line = "Error Domain=NSCocoaErrorDomain Code=4 UserInfo={NSFilePath=\(Self.file)}"
        let anonymized = anonymizer.anonymize(line)
        for secret in Self.secrets {
            #expect(!anonymized.contains(secret), "「\(secret)」が残っています → \(anonymized)")
        }
        #expect(anonymized.contains("NSCocoaErrorDomain"))
    }
}
