import Foundation

/// パス全体の長さの上限を尋ねる、ただ 1 つの窓口。
///
/// ## なぜ要るのか（実測）
/// 名前 1 つの上限とは別に、**絶対パス全体**に上限がある。深い階層のフォルダを
/// さらに深い場所へコピーすると、途中まで書いたところで `ENAMETOOLONG` に
/// なる。実際、フォルダを自身の子孫へコピーした実測では `copyfile(3)` が
/// 332 階層まで自己増殖してからこのエラーで止まり、ユーザーのフォルダの中に
/// ゴミの木を残した。
///
/// ## 上限は全形式で 1024 バイト（実測）
/// macOS がマウントし得る形式すべて（APFS / HFS+ / exFAT / FAT12・16・32 /
/// UDF / SMB〈実 NAS〉）で階層を掘り続けたところ、**いずれも 1019〜1023
/// バイトで `ENAMETOOLONG`** になった。ファイルシステム固有ではなく OS の
/// `PATH_MAX` が効いている。
///
/// `pathconf(_PC_PATH_MAX)` は APFS/HFS+/UDF/SMB では 1024 を返すが、
/// **exFAT と FAT では -1（不明）を返す**ため、その場合は `PATH_MAX` へ
/// 落とす（実測で同じ 1024 だと確認済み）。
enum PathLimits {
    /// `url` のあるボリュームで許されるパスの最大バイト数。
    ///
    /// 終端の NUL を含む値が返るため、実際に使える長さは 1 少ない。
    static func maxPathBytes(at url: URL) -> Int {
        let reported = url.withUnsafeFileSystemRepresentation { pointer -> Int in
            guard let pointer else { return -1 }
            errno = 0
            let value = pathconf(pointer, _PC_PATH_MAX)
            return value > 0 ? Int(value) : -1
        }
        // 分からない形式（exFAT/FAT）では OS の既定へ落とす。実測で同値。
        return (reported > 0 ? reported : Int(PATH_MAX)) - 1
    }

    /// `destination` の下に `relativePath` を置いたときのパスのバイト数。
    static func resultingPathBytes(destination: URL, relativePath: String) -> Int {
        destination.path.utf8.count + 1 + relativePath.utf8.count
    }
}
