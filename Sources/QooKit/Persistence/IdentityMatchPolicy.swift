import Foundation

/// **どこまでを黙って同じファイルとみなすか** [ID-13]。ライブラリ単位の設定。
///
/// ## なぜ設定にするか
///
/// 同一性の判定を厳しくすると「差し替えのたびにラベル・評価・タイトルを
/// 失わないための確認」が出るが、**差し替えは日常的に起きる**（スキャン版を
/// 電子版へ置き換える、等）。厳しさと煩わしさは正面から衝突し、どちらが正しいかは
/// 蔵書の扱い方によって変わる——だからアプリが決めずに選ばせる
/// ［設計の大原則: 機械が人間に合わせる］。
///
/// ## 何と何の境目か
///
/// `ReidentificationCandidate.Confidence` の 4 段のうち、**上 2 つは常に自動**
/// （中身が同じなので、そもそも差し替えではない）。この設定が動かすのは下 2 つ:
///
/// | 段 | 何が起きたか | `alwaysConfirm` | `samePath` | `sameName` |
/// |---|---|---|---|---|
/// | `.pathAndSize` | 上書き保存・再取得（中身は同じ）| 自動 | 自動 | 自動 |
/// | `.nameAndSize` | 移動しただけ | 自動 | 自動 | 自動 |
/// | `.pathOnly` | **同じ場所での差し替え** | 確認 | 自動 | 自動 |
/// | `.nameOnly` | 移動＋差し替え、別作品の同名 | 確認 | 確認 | 自動 |
///
/// ## 既定が `sameName` である理由［ユーザー判断］
///
/// **既定ではダイアログを出さない。** 引き換えに、別シリーズの同名ファイル
/// （`第01巻.cbz` のようにシリーズ名を含まない名前）へラベルが黙って移りうる。
/// 実際に起こるのは「孤立した行」と「新しく見つかった行」が同じライブラリ内に
/// 同時に存在するときだけで、プリセットのフォーマットはファイル名に作品名を
/// 含むため衝突しにくい。誤って引き継いだ場合は右ペインで直せる。
///
/// 確認を望む人は `alwaysConfirm` を選ぶ——**この設定が無ければ選べない**、
/// というのが器を用意した理由である。
public enum IdentityMatchPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// 中身が変わっていれば必ず確認する。最も安全で、最も尋ねる。
    case alwaysConfirm
    /// 同じ場所での差し替えは黙って引き継ぎ、場所が変わるものだけ確認する。
    case samePath
    /// ファイル名が同じなら、場所も中身も問わず引き継ぐ（既定）。
    case sameName

    public static let `default`: Self = .sameName

    /// この確度を**自動で**引き継いでよいか。
    ///
    /// **判断はこの 1 箇所だけが持つ。** 走査（`ScanEngine`）も、走査後の
    /// 確認ダイアログの引き直しも、同じ関数を通す——2 箇所に条件を書くと、
    /// 「自動で引き継いだはずのものが確認一覧にも出る」という食い違いになる。
    public func acceptsAutomatically(_ confidence: ReidentificationCandidate.Confidence) -> Bool {
        switch confidence {
        case .pathAndSize, .nameAndSize:
            // 中身が同じ＝差し替えではないので、どの設定でも自動 [ID-03]①②。
            return true
        case .pathOnly:
            return self != .alwaysConfirm
        case .nameOnly:
            return self == .sameName
        }
    }
}
