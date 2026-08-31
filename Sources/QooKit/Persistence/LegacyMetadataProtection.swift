//
//  置き換える前の保護の印を、保護スコープへ読み替える規則 [PR-08]。
//
//  **DB の移行（`v10_metadataProtection`）と JSON の取り込みの両方がここを
//  通る。** 片方だけ直すと、以前書き出した文書と DB とで変換結果が食い違う
//  ——巻数記法の旧表記で同じ轍を踏んでいる（`LegacyVolumeNotation`）。
//
//  DB 側は 10 万行を 1 文の SQL で変換するため、綴りを**引数として**渡して
//  規則そのものはここに残す形にしてある。
//
import Foundation

public enum LegacyMetadataProtection {
    /// 旧 `managedFile.titleOrigin` が「手で直した」を表す値。
    public static let manualTitle = "manual"
    /// 旧 `fileLabel.origin` のうち、**保護へ読み替えるもの**。
    ///
    /// `manuallyRemoved` も含めるのが要点。あれは「このラベルは付けないと
    /// 決めた」という意思表示で、行を消すだけでは次の走査で復活する
    /// ——フィールドごと保護しておけば走査はそこに触れない。
    public static let protectingLabelOrigins = ["manual", "manuallyRemoved"]
    /// 旧 `fileLabel.origin` のうち、**行そのものは残さない**もの。
    public static let removedLabelOrigin = "manuallyRemoved"

    public static func basicIsProtected(titleOrigin: String?) -> Bool {
        titleOrigin == manualTitle
    }

    public static func fieldIsProtected(labelOrigin: String?) -> Bool {
        guard let labelOrigin else { return false }
        return protectingLabelOrigins.contains(labelOrigin)
    }

    /// その紐づけが実際に「付いている」ことを表すか。
    ///
    /// `nil`（版 3 以降の文書）は行があること自体が付与を意味する [PR-08]。
    public static func isAttached(labelOrigin: String?) -> Bool {
        labelOrigin != removedLabelOrigin
    }
}
