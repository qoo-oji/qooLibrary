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
