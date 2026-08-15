import Foundation
import QooKit

/// 書き込み先のファイルシステムが受け付ける「名前 1 つの長さ」の上限。
///
/// ## なぜ資源キーで済まないか（実測）
/// `pathconf(_PC_NAME_MAX)` はどの形式でも 255（UDF だけ 254）を返すが、
/// **その 255 が何の単位なのかは形式ごとに違う**。同じ名前でも通ったり
/// 弾かれたりする:
///
/// | 形式 | `あ` の最大個数 | `が`(NFC) の最大個数 | 実質の単位 |
/// |---|---|---|---|
/// | APFS / HFS+ | 255 | 127 | NFD 後の UTF-16 単位 255 |
/// | exFAT / FAT | 255 | 165 | （駆動側の正規化に依存）|
/// | **SMB（実 NAS で計測）** | **85** | **85** | **UTF-8 バイト 255** |
/// | UDF | 78 | 39 | さらに短い |
///
/// Apple Developer Forums にも「`NAME_MAX` は APFS では当てにならない」旨の
/// スレッドがある。つまり**単位は問い合わせられない**ので、実測した形式に
/// ついてだけ規則を持つ。
///
/// ## 何が困るのか
/// 日本語は 1 文字 3 バイト。**86 文字以上の名前は、Mac 内では作れるのに
/// NAS では作れない**。同人誌・コミックのファイル名では十分あり得る長さで、
/// 一括コピーの途中で止まる原因になる。
///
/// ## 判断の向き
/// 知らない形式では**検査しない**（`VolumeCapacity`・`PathLimits` と同じ
/// 判断）。ここで誤って断ると正当な操作ができなくなるのに対し、通しても
/// 失敗は `ENAMETOOLONG` として捕まり理由付きで伝わる。
enum NameLengthLimit {
    /// 長さの数え方。
    enum Unit {
        /// UTF-8 のバイト数（SMB で実測）。
        case bytes
        /// NFD 正規化後の UTF-16 単位（APFS/HFS+ で実測）。
        case decomposedUTF16
    }

    struct Rule {
        let unit: Unit
        let maximum: Int

        func length(of name: String) -> Int {
            switch unit {
            case .bytes: name.utf8.count
            case .decomposedUTF16: name.decomposedStringWithCanonicalMapping.utf16.count
            }
        }

        func accepts(_ name: String) -> Bool { length(of: name) <= maximum }
    }

    /// 書き込み先の規則。判断できなければ `nil`（＝検査しない）。
    ///
    /// **バイト単位の規則を持つのは、実測した `smbfs` だけ**。他は最も緩い
    /// 規則（`FileNameValidation` が入口で既に適用している）に委ねる。
    ///
    /// - Note: SMB の 255 バイトは**このマシンから 1 台の NAS に対して**
    ///   実測した値。より長い名前を受け付けるサーバが見つかった場合は、
    ///   形式で決め打ちするのをやめ、書き込み先を 1 度だけ試す形へ
    ///   作り替えること（判定を推測に戻さない）。
    static func rule(forVolumeAt url: URL) -> Rule? {
        switch fileSystemType(at: url) {
        case "smbfs":
            return Rule(unit: .bytes, maximum: 255)
        default:
            // APFS/HFS+/exFAT/FAT は入口の検査（NFD 後 255 単位）と同じか
            // それより緩いため、ここで重ねて見る意味が無い。
            return nil
        }
    }

    private static func fileSystemType(at url: URL) -> String {
        var info = statfs()
        // 書き込み先がまだ無い場合は、実在する祖先まで遡って尋ねる。
        var target = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        guard statfs(target.path, &info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
