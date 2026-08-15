import Foundation

/// 書き込み先の空き容量を尋ねる、ただ 1 つの窓口。
///
/// 展開前の検査 [EX-23]（`SecureExtractor`）と、コピー・クロスボリューム移動
/// 前の検査 [ER-03]（`FileOperationService`）が同じ判断基準を使うために
/// 切り出した。片方だけ別の資源キーを見ていると、同じ「空きが足りない」でも
/// 操作によって通ったり通らなかったりする。
public enum VolumeCapacity {
    /// 書き込み先の空き容量。**分からなければ `nil`**。
    ///
    /// ## 2 つのキーを見る理由（実測に基づく）
    /// 第一候補は `volumeAvailableCapacityForImportantUsageKey` — purgeable
    /// （削除可能なキャッシュ等）を勘定に入れた、Finder の表示に近い値。
    /// ステータスバー（`StatusBarView`）もこれを見せているので、
    /// 「表示上は足りるのに断られた」が起きないようにこれを優先する。
    ///
    /// **ただしこのキーは小さなボリュームで 0 を返す。** 実測:
    ///
    /// | ボリューム | important | plain |
    /// |---|---|---|
    /// | 200MB のディスクイメージ（空）| **0** | 208 MB |
    /// | 7.3GB の USB（4GB 使用）| 2.99 GB | 2.99 GB |
    /// | 起動ボリューム | 544 GB | 525 GB |
    ///
    /// システムが確保する分を引いた結果と思われるが、これをそのまま
    /// 「空きゼロ」と解釈すると、**空のボリュームへのコピーを全部断って
    /// しまう**（実際に回帰テストが捕まえた）。0 のときは素の
    /// `volumeAvailableCapacityKey` へ落とす。
    ///
    /// ## 分からないときは `nil` を返す（＝呼び出し側は検査を飛ばす）
    /// 断る側に倒さない [設計判断]。誤って断ると**正当な操作ができなくなる**
    /// のに対し、通してしまっても失敗は `ENOSPC` として捕まり、
    /// 「空き容量が足りません」と理由付きで伝わる（`FileOperationError`
    /// `copyFailed` 参照）。害の非対称が大きい。
    ///
    /// 書き込み先がまだ存在しない場合（展開先のフォルダをこれから作る等）は、
    /// 実在する祖先まで遡って尋ねる。
    public static func available(at url: URL) -> Int64? {
        var target = url
        let fm = FileManager.default
        // `pathComponents.count > 1` でルート（`/`）に達したら止める。
        // `deletingLastPathComponent()` はルートに対して `/..` を返すことが
        // あり、素朴な「変化しなくなるまで」判定は無限ループになる
        // （本プロジェクトで 2 度踏んでいる）。
        while !fm.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        let values = try? target.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }
}
