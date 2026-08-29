import Foundation
import QooKit

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
        // **プライバシー保護された場所は読まない**［ユーザー報告で発覚、2026-08-29］。
        // 判定はここで行う——呼び出し側に委ねると、経路が増えたときに忘れる
        // （`isRemote` の判定を呼び出し側に置いていて、実際にこの穴が空いた）。
        if isPrivacyProtected(url) { return nil }
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

    // MARK: - 配下の集計 [DT-05][DT-06]

    /// 配下に含まれるファイル数・フォルダ数・合計サイズ。
    public struct ContainedCounts: Sendable, Hashable {
        public let fileCount: Int
        public let folderCount: Int
        public let totalSize: Int64
        public init(fileCount: Int, folderCount: Int, totalSize: Int64) {
            self.fileCount = fileCount
            self.folderCount = folderCount
            self.totalSize = totalSize
        }
    }

    /// 配下を再帰的に数える [DT-05][DT-06]。**`FileIO.perform` の中から呼ぶこと。**
    ///
    /// **プライバシー保護された場所へは降りない**［ユーザー報告で発覚、
    /// 2026-08-29］。`~/Library` を選ぶと配下を丸ごと列挙するので、
    /// `Containers`・`CloudStorage`・`Mail` 等に降りて**フォルダを選んだだけで
    /// TCC の許可ダイアログが次々に出る**（1 つ許可すると次が出る）。数える
    /// ためだけに他アプリのデータやメールを舐めるのは、機能として要らない
    /// うえに利用者へ不要な許可を求めることになる。
    ///
    /// **判定をここに閉じ込めてある**——呼び出し側に任せると、経路が増えた
    /// ときに忘れる（三角判定で実際にその形の穴が空いた）。
    ///
    /// - Returns: 打ち切られたら `nil`。**途中まで数えた値は返さない**
    ///   ——呼び出し側がそれを確定値として表示してしまう [レビューで発見]。
    public static func containedCounts(at url: URL) -> ContainedCounts? {
        // **起点そのものも検査する**［テストで発覚、2026-08-29］。列挙中の項目
        // だけを見ていると、`~/Library/Containers` を**直接選んだ**ときに素通り
        // する——実測で 741 フォルダを数えに行き、当然ダイアログが出た。
        // 「配下へ降りない」ガードは、入口にも要る。
        if isPrivacyProtected(url) {
            return ContainedCounts(fileCount: 0, folderCount: 0, totalSize: 0)
        }
        var fileCount = 0
        var folderCount = 0
        var totalSize: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return ContainedCounts(fileCount: 0, folderCount: 0, totalSize: 0)
        }
        for case let itemURL as URL in enumerator {
            // **`Task.isCancelled` ではない** — 借りたスレッドには Task の
            // 文脈が無く、常に `false` を返す [`Cancellation` 参照]。
            if Cancellation.isRequested { return nil }
            if isPrivacyProtected(itemURL) {
                enumerator.skipDescendants()
                folderCount += 1   // 「そこにフォルダがある」ことは数える
                continue
            }
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                folderCount += 1
            } else {
                fileCount += 1
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        return ContainedCounts(fileCount: fileCount, folderCount: folderCount, totalSize: totalSize)
    }

    // MARK: - プライバシー保護された場所 [ユーザー報告、2026-08-29]

    /// TCC（プライバシー保護）の許可を要する場所か。**ファイルシステムに
    /// 一切問い合わせない**——パス文字列だけで判定する。
    ///
    /// ## なぜ要るか
    /// `~/Library` をフォルダツリーで開くと、直下の**全フォルダ**（この機では
    /// 98 件）に対して三角を出すかどうかを決める `readdir` が走る。その中には
    /// `CloudStorage`（iCloud Drive の実体）・`Containers`・`Mail`・`Safari` など
    /// **TCC 保護対象が 7 種類**含まれており、**フォルダを開いただけで許可
    /// ダイアログが次々に出る**（1 つ許可すると次が出る）。
    ///
    /// 蔵書管理アプリが、三角マークを描くためだけに他アプリのコンテナや
    /// メールのデータを舐めに行くのは、機能として要らないだけでなく
    /// **利用者に不要な許可を求める**ことになる。
    ///
    /// ## なぜパスで判定するのか
    /// `CloudSyncLocation`（`NSFileProviderManager`）は使えない——**あれ自体が
    /// 同じ TCC 許可を要求する API** なので、判定しようとした瞬間にダイアログが
    /// 出る。**触れずに答えられる手段でなければ意味が無い。**
    ///
    /// ## 既存のガードでは足りなかった
    /// `FolderTreeNode` は `MountTable.isRemote` でネットワークを除いていたが、
    /// **File Provider 系（iCloud・Google Drive 等）は `volumeIsLocal` が真を返し、
    /// マウント表にもローカルとして載る**ので素通りする（8章 §8.11、NV-70〜74 に
    /// 実測記録がある）。知見はあったのに、三角判定を足したときに適用漏れした。
    ///
    /// - Returns: 保護対象、またはその配下なら `true`。
    public static func isPrivacyProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for prefix in protectedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    /// 保護対象の絶対パス。**場所は macOS が固定しているのでパスで書ける。**
    ///
    /// 実ホームから組み立てる——サンドボックス下の
    /// `FileManager.homeDirectoryForCurrentUser` はコンテナを返すが、
    /// `getpwuid(getuid())->pw_dir` は実ホームを返す [1-16 の実測]。
    private static let protectedPrefixes: [String] = {
        guard let pw = getpwuid(getuid()) else { return [] }
        let home = String(cString: pw.pointee.pw_dir)
        let library = home + "/Library"
        return [
            // File Provider の置き場（iCloud Drive・Google Drive・Dropbox 等）
            library + "/CloudStorage",
            // iCloud Drive の旧来の置き場
            library + "/Mobile Documents",
            // 他アプリのデータ [kTCCServiceSystemPolicyAppData]
            library + "/Containers",
            library + "/Group Containers",
            library + "/Application Support",
            // 個別に保護されているもの
            library + "/Mail",
            library + "/Safari",
            library + "/Messages",
            library + "/Cookies",
            library + "/IdentityServices",
            library + "/HomeKit",
            library + "/Suggestions",
            library + "/Metadata/CoreSpotlight",
        ]
    }()
}
