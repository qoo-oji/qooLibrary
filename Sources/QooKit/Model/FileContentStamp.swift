import Foundation

/// 「**どのファイルの、どの内容か**」を表す印。生成物のキャッシュに使う。
///
/// ## `FileIdentity` との違い
/// `FileIdentity`（volumeUUID + inode）は「どのファイルか」だけを表す
/// [ID-01]。中身が書き換わっても改名されても同じ値であることが、まさに
/// あの型の役目である（DB の同一性キー・`OpReceipt` の Undo はそれに
/// 依存している）。
///
/// そのため**キャッシュの鍵には使えない**。実際、サムネイルのキャッシュを
/// `FileIdentity` だけで引いていた結果、次の 2 つが起きていた:
///
/// 1. 外部でファイルを差し替えても、古いサムネイルが出続ける。
/// 2. 削除して新規作成すると inode が再利用されることがあり、**まったく
///    無関係なファイルのサムネイルが表示される**。
///
/// この型は識別に「内容の版」（更新日時とサイズ）を足すことで、その 2 つを
/// どちらも塞ぐ。更新日時はナノ秒まで持つ（APFS が保持しており、同じ秒内の
/// 連続した書き換えを取り逃がさないため）。サイズも併せて見るのは、
/// 更新日時を保ったまま内容が入れ替わる経路（`touch -r`、一部の同期ツール）
/// への備え。
///
/// ## フォルダに対して使う場合の限界
/// フォルダの更新日時は**直下の項目の増減・改名**でしか動かない。孫以下の
/// 画像を差し替えただけではこの印が変わらないため、フォルダのカバー画像は
/// 古いままになり得る。`QuickLookCoverStore` も同じ前提で動いており、
/// 完全な追随は Phase 2 のカバー解決（ユーザー指定・サイドカー）を実装する
/// ときに改めて検討する。
public struct FileContentStamp: Sendable, Hashable, Codable {
    public let identity: FileIdentity
    /// 更新日時（Unix 時刻の秒）。
    public let modifiedSeconds: Int64
    /// 更新日時の秒未満（ナノ秒）。
    public let modifiedNanoseconds: Int64
    /// バイト数。ディレクトリの場合は意味を持たないことがある。
    public let size: Int64

    public init(identity: FileIdentity, modifiedSeconds: Int64, modifiedNanoseconds: Int64, size: Int64) {
        self.identity = identity
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.size = size
    }

    /// キャッシュのファイル名などに使える、この印を一意に表す文字列。
    ///
    /// ボリューム UUID にハイフンが含まれるため、成分の切れ目を数えて
    /// 逆算できる形式ではない。**この文字列から元の値を復元しようとしない
    /// こと**（キャッシュは再生成できるので、必要が生じることも無い）。
    public var cacheKey: String {
        "\(Self.cacheKeyPrefix(for: identity))\(modifiedSeconds)-\(modifiedNanoseconds)-\(size)"
    }

    /// 同じファイルの**あらゆる版**に共通する接頭辞。「このファイルの
    /// キャッシュをすべて捨てる」に使う。末尾のハイフンが要点で、これが
    /// 無いと inode 123 の接頭辞が inode 1234 の鍵にも一致してしまう。
    public static func cacheKeyPrefix(for identity: FileIdentity) -> String {
        "\(identity.volumeUUID)-\(identity.inode)-"
    }
}
