import FileProvider
import Foundation

/// **その場所がクラウド同期（File Provider）の配下かどうか** [NV8-04]。
///
/// ## なぜ知る必要があるのか
/// 同期サービスは、ファイルシステムより**厳しい制約**を持つ。しかも
/// **破ってもエラーが出ない** — コピーも作成も成功し、そのファイルだけが
/// 永久に同期されない。既存の事前検査はどれも通してしまう:
///
/// | 制約 [文献] | 値 | 今の事前検査 |
/// |---|---|---|
/// | OneDrive/SharePoint のパス長 | **400 文字**（macOS は 1024）| `pathconf` は 1024 を返す → 通る |
/// | 禁止文字 `" * : < > ? \|` | Dropbox・OneDrive・Box に共通 | `FileNameValidation` は macOS 基準（`/` と `.` のみ）→ 通る |
/// | 1 ファイルの大きさ上限 | プロバイダごと | `volumeMaximumFileSize` は APFS の値 → 通る |
///
/// 本アプリは `(成年コミック) [作者] タイトル 第01巻` のような長く記号を含む
/// 名前を常態的に扱うので、400 文字制限は現実に踏む。
///
/// ## それでも「拒否」ではなく「知らせる」に留める理由
/// **プロバイダごとの正確な上限を、こちらから確かめる術が無い。** 個別ファイルの
/// 同期エラーを問い合わせる公開 API は見当たらず（`NSURLUbiquitousItem…ErrorKey`
/// は iCloud 専用）、上記の数値はいずれも [文献] であって実測ではない。
/// 裏を取れていない数値でユーザーの操作を止めるのは、本プロジェクトの
/// 「誤って断らない」原則に反する。だから**登録のときに一度だけ伝える**。
///
/// ## 判定の仕組み（実測で選んだ）
/// `NSFileProviderManager.getIdentifierForUserVisibleFile(at:)` を使う。
/// ヘッダには「自分の provider/domain 以外は `NSFileNoSuchFileError`」と
/// 読める書き方がされているが、**実際には他社・Apple のドメインも判定できる**:
///
/// | 対象 | 結果 | 所要 |
/// |---|---|---|
/// | iCloud Drive | `domain=8031FBC9-…` | 2.1ms |
/// | ローカル・SMB | `NSFileNoSuchFileError`(4) | 0.3〜0.8ms |
///
/// **App Sandbox 下でも動く**（実アプリと同じ entitlement で署名した最小アプリで
/// 確認。アクセスできる場所なら 0.3〜1.8ms で答える）。`getDomains` のほうは
/// `-2001` で使えないので、これが唯一の入口である。
///
/// - Important: **1 回の登録につき 1 回だけ呼ぶ。** XPC の往復なので、
///   ファイルごとに呼んではならない [NV-98]。ふつうは数ミリ秒だが、機械が
///   混んでいると**秒単位まで伸びる**（テスト全体を並行で回したとき 6 秒を
///   観測した）。だから上限時間を付けてある——登録は人が待つ操作なので、
///   `fileproviderd` が詰まっていても巻き添えにしない。
///
/// - Note: **「クラウドではない」と答える側は実測済みだが、「クラウドである」と
///   答える側はこの開発機で end-to-end に確かめられていない** — 開発機には
///   クラウドストレージが 1 つも無い（`~/Library/CloudStorage` は空、
///   iCloud Drive は 0 件）。プロバイダを 1 つ入れられる環境が手に入ったら、
///   ①登録時に実際に警告が出るか ②`domainIdentifier` に何が入るか、を
///   確かめること。
public enum CloudSyncLocation {
    /// クラウド同期の配下だと分かったときの手掛かり。
    public struct Detection: Sendable, Equatable {
        /// File Provider のドメイン識別子。iCloud では素の UUID になるため、
        /// **ユーザーに見せる名前としては使えない**（ログ用）。
        public let domainIdentifier: String?
        /// パスから読み取れる提供元の名前（`OneDrive`、`Dropbox` 等）。
        /// `~/Library/CloudStorage/<Provider>-<Account>` の形から取る。
        public let providerName: String?
    }

    /// この場所がクラウド同期の配下なら手掛かりを返す。違う・分からないなら `nil`。
    ///
    /// **分からない場合に `nil` を返す**のが要点で、疑わしきは黙る
    /// （根拠の無い警告を出さない）。
    public static func detect(at url: URL) async -> Detection? {
        let providerName = providerNameFromPath(url)
        // パスから明らかなら、XPC の往復を待つまでもない。
        if let providerName {
            return Detection(domainIdentifier: await domainIdentifier(for: url), providerName: providerName)
        }
        guard let domain = await domainIdentifier(for: url) else { return nil }
        return Detection(domainIdentifier: domain, providerName: nil)
    }

    // MARK: - 内部

    /// File Provider へ問い合わせる。**上限時間を付ける** — `fileproviderd` との
    /// XPC なので、相手が詰まっているときに登録を巻き添えにしない。
    private static func domainIdentifier(for url: URL) async -> String? {
        try? await FileIO.withDeadline(.seconds(5)) {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { _, domain, error in
                    if let error {
                        // `NSFileNoSuchFileError`(4) は「ドメイン配下ではない」の意味で、
                        // 異常ではないのでログにも残さない（実測で確認）。
                        let code = (error as NSError).code
                        if code != NSFileNoSuchFileError {
                            Log.fileOps.debug(
                                "File Provider の判定ができませんでした（\(code)）: \(Log.path(url))"
                            )
                        }
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: domain?.rawValue)
                    }
                }
            }
        } ?? nil
    }

    /// `~/Library/CloudStorage/OneDrive-Contoso/…` のような置き場から提供元を取る。
    ///
    /// **API の答えを補うもの。** ドメイン識別子は iCloud では素の UUID なので、
    /// ユーザーに見せられる名前はこちらからしか得られない [文献: macOS 13 以降、
    /// 主要プロバイダはすべてこの置き場を使う]。
    static func providerNameFromPath(_ url: URL) -> String? {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let index = components.firstIndex(of: "CloudStorage"),
              index > 0, components[index - 1] == "Library",
              components.count > index + 1
        else { return nil }
        // `OneDrive-Contoso` → `OneDrive`。区切りが無ければそのまま。
        let entry = components[index + 1]
        return entry.split(separator: "-", maxSplits: 1).first.map(String.init) ?? entry
    }
}
