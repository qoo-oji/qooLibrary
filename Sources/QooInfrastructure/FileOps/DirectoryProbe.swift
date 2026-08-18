import Foundation

/// ディレクトリの中身についての、**読み取りだけの軽い問い合わせ**。
///
/// `FileOps/` に置いてあるが変更系の API は使わないので、隔離検査 [FO-02][B-10]
/// の対象ではない（`MountTable` と同じ扱い）。
public enum DirectoryProbe {
    /// 直下にサブフォルダが 1 つでもあるか。判定できなければ `nil`。
    ///
    /// **メインアクタの外で呼ぶこと** [NV6-02]。応答しない共有では
    /// `opendir(3)` の時点で止まる。
    ///
    /// `readdir(3)` を最初のサブフォルダで打ち切る。`d_type` を見れば 1 件
    /// ごとの `stat` が要らないので、`contentsOfDirectory` +
    /// `resourceValues` より桁で速い（[実測] 2,000 件・サブフォルダ無しの
    /// フォルダで 0.89 ms 対 4.66 ms。200 件なら 0.14 ms 対 1.01 ms。
    /// サブフォルダが早い位置にあれば 0.09 ms で打ち切れる）。
    ///
    /// **安い判定手段は他に無いことを確かめてある**: ディレクトリの
    /// `st_nlink` は APFS では「2 ＋ **全**エントリ数」で、サブフォルダ数
    /// ではない（[実測]。HFS+ の古い規約とは違う）。`URLResourceKey` の
    /// `.directoryEntryCount`／`.linkCount` も全エントリ数で、どちらも
    /// ファイルとフォルダを区別しない。
    ///
    /// - Parameter includingHidden: `.` で始まる名前も数えるか。既定は
    ///   `false` で、`FileManager` の `.skipsHiddenFiles` に合わせる
    ///   ——**呼び出し側が一覧に使う規則と揃えること**。ここで数えたものと、
    ///   実際に一覧へ出るものが食い違ってはならない。
    public static func hasSubdirectory(at url: URL, includingHidden: Bool = false) -> Bool? {
        guard let dir = opendir(url.path) else { return nil } // 読めない → 不明
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            var value = entry.pointee
            let name = withUnsafePointer(to: &value.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            if !includingHidden, name.hasPrefix(".") { continue }

            switch Int32(value.d_type) {
            case DT_DIR:
                return true
            case DT_LNK, DT_UNKNOWN:
                // `.isDirectoryKey` はリンクを辿るので、ディレクトリへの
                // シンボリックリンクは一覧に「フォルダ」として現れる。
                // ここでも辿って数える（`lstat` ではなく `stat`）。
                // `DT_UNKNOWN` を返すファイルシステムのための保険でもある。
                var status = stat()
                if stat(url.appendingPathComponent(name).path, &status) == 0,
                   (status.st_mode & S_IFMT) == S_IFDIR {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}
