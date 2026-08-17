import Foundation

extension Int64 {
    /// あふれたら `Int64.max`（負方向は `Int64.min`）へ張り付く加算。
    ///
    /// **アーカイブのヘッダが宣言するサイズの合算に使う** [フェーズ1完了時の
    /// 監査で追加]。宣言値は攻撃者が自由に書ける（zip64/RAR は 8 バイト全域を
    /// 表現できる）ため、素の `+` で合算すると、`Int64.max` 級の値を 2 つ
    /// 並べただけのアーカイブで Swift の桁あふれ検査がトラップし、上限検査に
    /// 到達する前にアプリごと落ちる。飽和させておけば、その後の
    /// 「上限を超えている」判定が正しく拒否してくれる。
    public func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other >= 0 ? .max : .min
    }
}
