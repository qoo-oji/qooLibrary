import Foundation

/// アプリ全体の定数を集約する [4章 命名規約]。マジックナンバーの直書き禁止。
public enum AppLimits {
    /// 展開時の安全上限 [EX-20〜EX-22]。環境設定で変更できる想定のため、
    /// ここに置くのは既定値のみ。
    public enum Extraction {
        /// 展開後の総バイト数の上限（既定 20GB）。宣言された非圧縮サイズではなく
        /// 書き出し中の実バイト数で判定する [EX-20]。
        public static let defaultMaxUncompressedBytes: Int64 = 20 * 1_000 * 1_000 * 1_000
        /// エントリ数の上限（既定 100,000）。
        public static let defaultMaxEntries: Int = 100_000
        /// 圧縮比がこの倍率を超えたら警告する（既定 100 倍）。
        public static let defaultRatioWarn: Double = 100
        /// 圧縮比がこの倍率を超えたら中断する（既定 1,000 倍）。
        public static let defaultRatioAbort: Double = 1_000
        /// 展開先ボリュームに確保しておく空き容量の余裕分（既定 1GB）。
        public static let defaultFreeSpaceMargin: Int64 = 1_000 * 1_000 * 1_000
    }

    /// サムネイル生成の安全上限・既定値 [9.5〜9.6 節]。
    public enum FileOperations {
        /// コピー・クロスボリューム移動を始める前に、この分だけ余分に
        /// 空きを要求する [ER-03、`SecureExtractor` の [EX-23] と同じ考え方]。
        ///
        /// 運ぶバイト数は実測なので、展開時（宣言値が嘘をつき得るので 1GB）
        /// ほど厚い余裕は要らない。ディレクトリツリーの inode やメタデータが
        /// 消費する分を吸収できればよいので小さくしてある — 大きくすると
        /// 「空き 2.5GB へ 2GB のコピー」のような正当な操作まで断ってしまう。
        public static let freeSpaceMargin: Int64 = 64 * 1_000 * 1_000

        /// `NSWorkspace.recycle` の完了を待つ上限（秒）[NV4-04]。
        ///
        /// **UI 文脈を持たないプロセスでは完了ハンドラが永久に呼ばれない**
        /// （1-16b の実測で 40 秒以上確認）。`FileOperationService` は `actor`
        /// なので、待ち続けると**アプリの全ファイル操作が止まる**。
        ///
        /// ゴミ箱を持たない場所では macOS が確認ダイアログを出し、**ユーザーが
        /// 答えるまで完了しない**——人が席を外す時間を見込んで長めに取る。
        /// 短くすると「考えていたら勝手に打ち切られた」になる。
        public static let trashTimeoutSeconds: Double = 120

        /// Security-Scoped Bookmark の解決を待つ上限（秒）[NV-91][NV6-05]。
        ///
        /// 解決は `.withoutMounting` を付けても、**マウント済みなのに応答しない**
        /// 共有へは対象を確かめるために出て行ってブロックする（SMB は既定 30 秒、
        /// NFS の hard マウントなら無限）。ストアは `FileIO` 経由で解決しつつ
        /// この上限で**待つのをやめ**、超えた解決は「応答なし」
        /// （`OfflineReason.unresponsive`）として扱う。走っている解決自体は
        /// 止まらない [NV6-03]。
        ///
        /// 正常な共有の解決は ms 単位なので 5 秒は十分な余裕
        /// （`CloudSyncLocation`・起動時フォルダ解決の既存の上限と同じ値）。
        public static let bookmarkResolutionTimeoutSeconds: Double = 5

        /// 削除が**一過性の**失敗をしたときに試し直す回数 [1-16b の実測]。
        ///
        /// SMB では、中身のあるフォルダを消すと **5 回に 1 回ほど 1 回目が
        /// `EPERM` で失敗する**（実 NAS で 30 回中 6 回）。原因は子の削除が
        /// サーバ側で片付くまでのごく短い隙間で、**待てば必ず解ける** —
        /// 実測では 6 件すべてが復帰し、うち 2 件は即時、4 件は 100ms 後だった。
        ///
        /// 3 回（最大 300ms）あれば実測の範囲を十分に覆う。これ以上伸ばしても
        /// 意味は無い——**待っても直らない失敗は別種**（`ENOTEMPTY`。外部が
        /// ハンドルを開いている場合で、5 秒待っても解けない）であり、そちらは
        /// そもそも再試行の対象にしない [NV90-01]。
        public static let transientRemovalRetries = 3

        /// 上記の試し直しの間隔（秒）。実測の復帰時刻（100ms）に合わせてある。
        public static let transientRemovalRetryDelay: Double = 0.1
    }

    public enum Thumbnail {
        /// 画像1枚あたりのピクセル数上限（既定 1 億）[IM-01]。
        public static let defaultMaxPixelCount: Int = 100_000_000
        /// アーカイブ内の1エントリを読み込む際の上限バイト数（既定 512MB）[IM-02]。
        public static let defaultMaxEntryReadBytes: Int = 512 * 1_000 * 1_000
        /// サムネイル生成の同時実行数上限（既定 4）[PF-11]。
        public static let defaultMaxConcurrent: Int = 4
        /// キャッシュディレクトリの合計サイズ上限（既定 500MB）[IV-09]。
        public static let defaultCacheMaxSize: Int64 = 500 * 1_000 * 1_000
        /// 動画サムネイル生成（`QLThumbnailGenerator` 経由）1件あたりのタイムアウト
        /// 秒数（既定 8秒）[ユーザー要望、要件定義書には無い]。実機検証で
        /// `qlmanage -t`（旧 CLI）がサードパーティ QuickLook 拡張との組み合わせで
        /// 応答せずハングする事例を確認したため、`PF-11` の同時実行スロットが
        /// 1件のハングで専有され続けないよう防御的に設けている。
        public static let defaultVideoThumbnailTimeoutSeconds: Double = 8
        /// mkv（Matroska/EBML）コンテナのヘッダから `PixelWidth`/`PixelHeight`
        /// を読むために先頭から読み込む上限バイト数（既定 8MB）[ユーザー要望:
        /// サムネイルのアスペクト比を実際の動画に合わせたい]。動画本体は
        /// デコードしない、コンテナのメタデータのみの軽量な読み取りのため、
        /// ファイルサイズが数GBでもこの範囲で十分足りる想定。見つからなければ
        /// 諦めて正方形のリクエストにフォールバックする。
        public static let defaultMatroskaHeaderScanBytes: Int = 8 * 1_000 * 1_000
        /// アイコン表示でフォルダのカバーとして重ねる、直下ファイルの最大枚数
        /// （既定 3）[ユーザー要望、要件定義書には無い]。
        ///
        /// **1 フォルダあたりの生成・読み込み件数がそのままこの倍率になる**
        /// ため、増やすときは可視セル数 × この値が `defaultMaxConcurrent` の
        /// キューにどれだけ積まれるかを意識すること。
        public static let defaultFolderCoverCount: Int = 3
        /// バックグラウンド動画サムネイル生成（`BackgroundThumbnailWarmer`、
        /// 9.6 節）[ユーザー要望、要件定義書には無い] が生成に使う辺の上限
        /// ピクセル数。**UI が要求し得る最大以上にすること** — キャッシュの鍵
        /// [TH-08] は要求サイズを含まないため、ここで小さく作ると単体表示が
        /// その粗いキャッシュを掴んでしまう。現状の最大はアイコンサイズ上限
        /// 256（`DesignTokens.json`）の Retina 2 倍 = 512（インスペクタは 320）。
        public static let defaultWarmedThumbnailPixelSize: Int = 512
        /// 同じ拡張子が 1 度も成功しないまま、この回数失敗したら「この形式は
        /// 生成できない」と見なしてそのセッションでは以降スキップする。
        /// 1 回にしないのは、たまたま先頭のファイルが壊れていただけで形式
        /// 全体を諦めないため。1 度でも成功した形式は以降スキップしない
        /// （失敗はファイル個別の問題と分かるため）。
        public static let warmerFormatFailureThreshold: Int = 3
        /// 掃引のやり直しの合図（登録フォルダの増減・アクセス権の変化等）を
        /// 待ち合わせて 1 回にまとめる時間（秒）。
        public static let warmerRestartDebounceSeconds: Double = 2
    }

    /// Quick Look [9.7 節、QL-01〜QL-10]。
    public enum QuickLook {
        /// 独自カバープレビュー用に書き出したファイルを溜めておく上限（既定 200MB）。
        ///
        /// このキャッシュはアプリ起動のたびに丸ごと捨てるセッション限りのもの
        /// （`QuickLookCoverStore` のコメント参照）だが、1 セッション中に大量の
        /// アーカイブをプレビューした場合の際限ない肥大を防ぐため、サムネイル
        /// キャッシュ [IV-09] と同じく上限を設けて古いものから削除する。
        /// 原画像をそのまま書き出す（再エンコードしない）ため 1 件あたりが
        /// サムネイル（PNG 縮小版）より大きく、別の上限にしている。
        public static let defaultCoverCacheMaxSize: Int64 = 200 * 1_000 * 1_000
    }

    /// 診断ログ [2章 §2.6、LG2-01〜LG2-08]。
    public enum Logging {
        /// 既定のログレベル（`info`）[LG2-03]。
        public static let defaultLevel: LogLevel = .info
        /// ログファイル 1 本あたりの上限バイト数（既定 10MB）[LG2-04][CB-20]。
        public static let defaultMaxFileBytes: Int64 = 10 * 1_000 * 1_000
        /// 保持する世代数（既定 5、`qoo-0.log` … `qoo-4.log`）[LG2-04][CB-20]。
        public static let defaultGenerations: Int = 5
        /// 書き出し待ちレコードのバッファ上限。
        ///
        /// ログの書き込みは呼び出し元をブロックしないよう非同期の消費タスクへ
        /// 渡す [CB-21] が、ディスクが極端に遅い・止まっている場合に待ち行列が
        /// 無制限に伸びてメモリを食い潰さないよう上限を設ける。溢れた分は
        /// 古いものから捨て、捨てた件数を後続の行に注記する（黙って失う方が
        /// 危険なため）。
        public static let maxBufferedRecords: Int = 4_096
        /// 匿名化トークンの桁数（sha256 の先頭 8 桁）[CB-23]。
        public static let anonymizationTokenLength: Int = 8
    }

    /// 表示中のフォルダの変更検知 [10章 §10.0]。
    ///
    /// 仕様の `fsEventsLatency`（1.0 秒 [SY-07]）はライブラリのスキャン向けの
    /// 値で、UI の追随には別の物差しが要るため分けている。
    public enum Watch {
        /// FSEvents が変更をまとめて配送するまでの待ち時間（秒）。
        ///
        /// 短すぎると、Finder の 1 回の改名が生む 2 件のイベント（旧名の消失・
        /// 新名の出現）を別々に受け取って一覧が二度描き変わる。0.25 秒は
        /// 体感で即座であり、かつ 1 操作を 1 バッチにまとめられる値として選んだ。
        public static let coalescingLatency: Double = 0.25
        /// 監視ルート集合を組み直すまでの遅延（秒）。フォルダツリーを一気に
        /// 展開すると関心が数十件まとめて増えるため、その都度ストリームを
        /// 作り直さないよう短く待ち合わせる。
        public static let rootRebuildDebounce: Double = 0.1
        /// ネットワークボリューム上のフォルダを見張る間隔（秒）。
        ///
        /// FSEvents は**他のマシンが加えた変更を報告しない**（ローカルの
        /// カーネルを通った変更だけを見ている）ため、リモートボリューム上の
        /// フォルダを表示している間だけ、ディレクトリの更新日時を軽く
        /// 突き合わせる経路を併用する。アプリが前面にあるときだけ動く。
        public static let remotePollInterval: Double = 2.0
    }

    /// 中央ペインの検索 [1-16]。
    public enum Search {
        /// 再帰検索で保持する結果の上限。
        ///
        /// 1 ライブラリ 1万〜5万ファイル [C-07] を想定しており、短い語で検索
        /// すればほぼ全件が一致し得る。それをすべてメモリに積んで一覧へ流すのは
        /// 現実的でないため上限を設け、超えた時点で走査を打ち切る（打ち切った
        /// ことは UI 側に表示する）。
        public static let maxResults: Int = 2_000
        /// 一覧へ小出しにする単位。走査の完了を待たず、この件数ごとに反映して
        /// 「探している感じ」が出るようにする。
        public static let resultBatchSize: Int = 64
    }
}
