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
    /// - Parameter includingHidden: 隠し項目も数えるか。既定は `false` で、
    ///   `FileManager` の `.skipsHiddenFiles` に合わせる——**呼び出し側が
    ///   一覧に使う規則と揃えること**。ここで数えたものと、実際に一覧へ出る
    ///   ものが食い違ってはならない。
    ///
    ///   **「隠し」は名前の `.` 接頭辞だけではない** [ユーザー報告で発見]。
    ///   `UF_HIDDEN` フラグ（`chflags hidden`）が立った項目も Finder と
    ///   `.skipsHiddenFiles` は隠すので、ここでも数えない。実際に
    ///   `~/Downloads` がこの状態で、「空なのに三角が出る」という形で現れた
    ///   ——一覧には 1 件も出ないのに、`readdir` の名前だけを見ていたため
    ///   数えていた。
    /// - Parameter countingPackages: パッケージ（`.app` など）をサブフォルダと
    ///   して数えるか。フォルダツリーは**数えない**——ツリーにパッケージを
    ///   出さない以上、それを理由に三角を出すと「開いても何も無い」嘘になる。
    ///   `false` にすると `DT_DIR` の項目ごとに `isPackageKey` を引くので、
    ///   パッケージばかりのフォルダ（`/Applications` など）では打ち切りが
    ///   効かず全件走査になる（[実測] 45 件で 1 ミリ秒未満、`Utilities` を
    ///   含むので実際にはもっと早く打ち切れる）。
    public static func hasSubdirectory(
        at url: URL, includingHidden: Bool = false, countingPackages: Bool = true
    ) -> Bool? {
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
                let child = url.appendingPathComponent(name)
                if !includingHidden, isHiddenByFlag(child) { continue }
                if countingPackages || !isPackage(child) { return true }
            case DT_LNK, DT_UNKNOWN:
                // `.isDirectoryKey` はリンクを辿るので、ディレクトリへの
                // シンボリックリンクは一覧に「フォルダ」として現れる。
                // ここでも辿って数える（`lstat` ではなく `stat`）。
                // `DT_UNKNOWN` を返すファイルシステムのための保険でもある。
                var status = stat()
                let child = url.appendingPathComponent(name)
                if stat(child.path, &status) == 0,
                   (status.st_mode & S_IFMT) == S_IFDIR,
                   includingHidden || (status.st_flags & UInt32(UF_HIDDEN)) == 0,
                   countingPackages || !isPackage(child) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// `UF_HIDDEN` が立っているか（`chflags hidden`）。**名前の `.` 接頭辞とは
    /// 別の隠し方**で、`FileManager` の `.skipsHiddenFiles` も Finder も
    /// こちらを隠す。`stat(2)` 1 回で済むので `resourceValues` より軽い。
    ///
    /// 引けなければ「隠れていない」に倒す——数え落として三角が消えるより、
    /// 余分に数えて「開いたら空だった」で済ませるほうが害が小さい
    /// （`hasSubdirectory` の `nil` と同じ判断）。
    private static func isHiddenByFlag(_ url: URL) -> Bool {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return false }
        return (status.st_flags & UInt32(UF_HIDDEN)) != 0
    }

    /// Finder が 1 つの項目として扱うディレクトリか [`URLResourceKey.isPackageKey`]。
    /// 引けなければ「パッケージではない」に倒す——誤って数えても
    /// 「開いたら空だった」で済むが、数え落とすと開けるはずの行から三角が
    /// 消えて行き止まりになる。
    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}
