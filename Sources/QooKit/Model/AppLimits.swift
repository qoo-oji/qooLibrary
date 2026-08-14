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
    }
}
