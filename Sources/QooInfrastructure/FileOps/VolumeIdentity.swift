import CryptoKit
import Foundation

/// **ボリュームを区別するための識別子** [NV3-01]。
///
/// `FileIdentity` は「ボリューム UUID ＋ inode」の組で「どのファイルか」を
/// 表す [ID-01]。ところが **SMB では `volumeUUIDString` が必ず `nil` になる**
/// （1-16b の実測、8章 §8.11.2。Samba・Apple・Windows の 3 系統すべてで nil）。
///
/// 以前はそこを `?? ""` で埋めていた。つまり**マウントしているネットワーク
/// 共有すべてが同じ「ボリューム」に見えていた**。ネットワークの inode は
/// 小さな値なので、2 つの共有をマウントすれば別のファイルどうしが同じ
/// `FileIdentity` になるのは珍しくない。`FileIdentity` はサムネイルと
/// Quick Look のカバーのキャッシュ鍵に使われるので、そのとき起きるのは
/// **別の作品の表紙が表示される**ことである。
///
/// ## マウント元から作る
/// `statfs(2)` の `f_mntfromname` は、SMB なら `//user@host/share` の形で
/// **共有ごとに必ず異なる**。しかも再起動・再マウントをまたいでも同じ
/// 文字列になるので、ディスクに残るキャッシュが効き続ける
/// （`st_dev` は一意ではあるが再マウントで変わるため、毎回キャッシュが
/// 失効してネットワークで最悪の I/O 増幅を招く）。
///
/// **そのまま使わずハッシュする**。この値はキャッシュの**ファイル名**に
/// なるので、①`/` を含むと使えない ②ユーザー名とホスト名がキャッシュ
/// ディレクトリの一覧に露出する、の 2 つを避ける必要がある。
///
/// ## 直らないもの [NV3-03]
/// **Samba の共有内での `st_ino` 再利用**はこれでは直らない（`st_ino` が
/// パス名から合成される値で、削除→同名で作り直すと同じ値が返る）。
/// ただしキャッシュの鍵は `FileContentStamp`（＝ identity ＋ 更新日時 ＋
/// サイズ）なので、別のファイルが同じ場所に同じ大きさ・同じ更新日時で
/// 現れない限り衝突しない。**ネットワーク上では同一性そのものを当てに
/// しない**という原則は変わらない。
enum VolumeIdentity {
    /// `url` のあるボリュームの識別子。`volumeUUIDString` があればそれを、
    /// 無ければマウント元から導いた `net-<hash8>` を返す。
    ///
    /// どちらも取れなければ `nil`。**空文字を返してはならない** —
    /// それが上記の取り違えの原因だった。
    static func identifier(for url: URL) -> String? {
        if let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            return uuid
        }
        guard let source = mountSource(for: url) else { return nil }
        return "net-\(hash8(source))"
    }

    /// `statfs(2)` が答える「何をマウントしたものか」。
    /// SMB なら `//user@host/share`、ローカルなら `/dev/disk3s5` 等。
    private static func mountSource(for url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntfromname) { raw in
            guard let base = raw.baseAddress else { return nil }
            let value = String(cString: base.assumingMemoryBound(to: CChar.self))
            return value.isEmpty ? nil : value
        }
    }

    private static func hash8(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
