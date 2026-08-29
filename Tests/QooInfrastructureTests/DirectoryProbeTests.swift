import Foundation
import QooKit
import Testing
@testable import QooInfrastructure

/// 「直下にサブフォルダがあるか」の判定 [フォルダツリーの三角マークの
/// 出し分け]。**数える規則が `FileManager` の一覧と食い違うと、
/// 三角の有無と実際に開いたときの中身がずれる**ので、隠しファイルの扱いと
/// シンボリックリンクの扱いをここで固定する。
struct DirectoryProbeTests {
    /// 使い捨ての作業ディレクトリ。
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 隠し項目 [ユーザー報告: 空のはずのフォルダに三角が出る]

    /// **`UF_HIDDEN` は名前の `.` 接頭辞とは別の隠し方。**
    /// `FileManager` の `.skipsHiddenFiles` も Finder もこれを隠すので、
    /// ここでも数えない——数えると「一覧には何も出ないのに三角だけがある」
    /// 状態になる（実際に `~/Downloads` がこの状態だった）。
    @Test func foldersHiddenByFlagAreNotCounted() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent("PlainName")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.init(rawValue: FileAttributeKey.immutable.rawValue): false], ofItemAtPath: hidden.path)
        // `chflags hidden` 相当。`FileAttributeKey` には無いので直に立てる。
        var status = stat()
        #expect(stat(hidden.path, &status) == 0)
        #expect(chflags(hidden.path, status.st_flags | UInt32(UF_HIDDEN)) == 0)

        // 一覧（`.skipsHiddenFiles`）に出ないことを先に確かめる——**この前提が
        // 崩れたらテストの意味が無くなる**ので一緒に固定する。
        let listed = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        #expect(listed.isEmpty)

        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
        #expect(DirectoryProbe.hasSubdirectory(at: root, includingHidden: true) == true)
    }

    // MARK: - パッケージ [ユーザー要望: `.app` は 1 つの項目として扱う]

    /// フォルダツリーはパッケージを行として出さない。**それを理由に三角を
    /// 出すと「開いても何も無い」嘘になる**ので、数にも入れない。
    @Test func packagesAreNotCountedWhenAsked() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Test.app", "Test.bundle", "Test.rtfd"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        // 既定（`countingPackages: true`）は従来どおり数える——中央ペインの
        // ように「実体がディレクトリか」を知りたい呼び出し側のため。
        #expect(DirectoryProbe.hasSubdirectory(at: root) == true)
        #expect(DirectoryProbe.hasSubdirectory(at: root, countingPackages: false) == false)
    }

    /// パッケージに混じって素のフォルダが 1 つでもあれば数える。
    /// **打ち切りの位置を間違えると、パッケージで止まって取りこぼす。**
    @Test func aPlainFolderAmongPackagesIsStillFound() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // 名前順でパッケージが先に来るようにする（`/Applications` と同じ形）。
        for name in ["A.app", "B.app", "Utilities"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        #expect(DirectoryProbe.hasSubdirectory(at: root, countingPackages: false) == true)
    }

    /// **[既知の限界] パッケージへのシンボリックリンクは数えてしまう。**
    ///
    /// `URLResourceKey` はリンクを辿らないので（[実測] `isDirectory` すら
    /// `false` を返す）、`isPackage` はリンク自身を見て `false` になる。
    /// 一方この関数の `DT_LNK` 経路は `stat(2)` で辿るため「ディレクトリが
    /// ある」と数える。
    ///
    /// **これはリンク全般が抱える既存の不整合の一部で、パッケージ固有では
    /// ない。** `FolderTreeNode.children(of:)` も同じ `isDirectory` で弾くため
    /// **シンボリックリンクはそもそもツリーに行として出ない**（[実測]）——
    /// つまり「リンクだけがあるフォルダは三角が出るが、開くと空」という
    /// 食い違いが以前からある（仕様 [SL-01][SL-06] は「リンク自体を 1 項目
    /// として表示する」と定めており、実装がそこに追いついていない）。
    ///
    /// ここではその実態を固定するに留める——直すなら `children(of:)` 側で
    /// リンクを表示できるようにするのが筋で、パッケージの都合で片側だけ
    /// 変えると食い違いが増える。
    @Test func aSymlinkToAPackageIsStillCounted() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        #expect(DirectoryProbe.hasSubdirectory(at: root, countingPackages: false) == true)
    }

    @Test func emptyDirectoryHasNoSubdirectory() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
    }

    @Test func directoryWithOnlyFilesHasNoSubdirectory() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.cbz", "b.cbz", "メモ.txt"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
    }

    /// サブフォルダが**最後**にある場合も見つける（早期終了の打ち切り位置を
    /// 間違えると、名前順で後ろにあるものを取りこぼす）。
    @Test func findsASubdirectoryThatComesAfterManyFiles() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<50 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("f\(index).cbz").path, contents: Data())
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zzz"), withIntermediateDirectories: false)
        #expect(DirectoryProbe.hasSubdirectory(at: root) == true)
    }

    /// 隠しフォルダしか無ければ「サブフォルダなし」。ツリーの一覧は
    /// `.skipsHiddenFiles` で隠しを外すので、数える側も外さないと
    /// 「三角はあるのに開くと空」になる。
    @Test func hiddenSubdirectoriesAreNotCountedByDefault() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
        #expect(DirectoryProbe.hasSubdirectory(at: root, includingHidden: true) == true)
    }

    /// **ディレクトリへのシンボリックリンクは数える。** 一覧側は
    /// `.isDirectoryKey`（リンクを辿る）でフォルダと判定して行に出すため、
    /// ここで数えないと「行はあるのに三角が無い」ことになる。
    @Test func aSymbolicLinkToADirectoryCounts() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: elsewhere)
        #expect(DirectoryProbe.hasSubdirectory(at: root) == true)
    }

    @Test func aSymbolicLinkToAFileDoesNotCount() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("real.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: file)
        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
    }

    /// リンク切れでも落ちない（`stat` が失敗するだけ）。
    @Test func aBrokenSymbolicLinkDoesNotCount() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("いない"))
        #expect(DirectoryProbe.hasSubdirectory(at: root) == false)
    }

    /// **判定できなければ `nil`。** 呼び出し側はこれを「不明」として扱い、
    /// 三角を出したままにする（誤って消すと開けなくなるため）。
    @Test func returnsNilWhenTheDirectoryCannotBeRead() throws {
        let root = try makeWorkspace()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        // root 権限で走っている環境では読めてしまうので、そのときは飛ばす。
        try #require(getuid() != 0)
        #expect(DirectoryProbe.hasSubdirectory(at: root) == nil)
    }

    @Test func returnsNilForAPathThatDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-probe-missing-\(UUID().uuidString)")
        #expect(DirectoryProbe.hasSubdirectory(at: missing) == nil)
    }
}

//
//  プライバシー保護された場所は読まない [ユーザー報告、2026-08-29]。
//
//  `~/Library` をツリーで開くと直下の全フォルダ（この機では 98 件）へ
//  `readdir` が走り、その中の TCC 保護対象が**フォルダを開いただけで
//  許可ダイアログを次々に出させていた**（1 つ許可すると次が出る）。
//

@Suite("プライバシー保護された場所の除外")
struct DirectoryProbePrivacyTests {

    private var home: String {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }

    @Test("File Provider の置き場は保護対象（iCloud・Google Drive 等）")
    func cloudStorageIsProtected() {
        #expect(DirectoryProbe.isPrivacyProtected(
            URL(fileURLWithPath: home + "/Library/CloudStorage")))
        // **配下も対象**——プロバイダごとのフォルダを開くのも同じ許可を要する。
        #expect(DirectoryProbe.isPrivacyProtected(
            URL(fileURLWithPath: home + "/Library/CloudStorage/iCloud Drive")))
    }

    @Test("他アプリのデータ領域は保護対象 [kTCCServiceSystemPolicyAppData]")
    func appDataIsProtected() {
        for name in ["Containers", "Group Containers", "Application Support"] {
            #expect(DirectoryProbe.isPrivacyProtected(
                URL(fileURLWithPath: home + "/Library/" + name)), "\(name) が保護対象と判定されない")
        }
    }

    @Test("メール・Safari・メッセージも保護対象")
    func personalDataIsProtected() {
        for name in ["Mail", "Safari", "Messages"] {
            #expect(DirectoryProbe.isPrivacyProtected(
                URL(fileURLWithPath: home + "/Library/" + name)), "\(name) が保護対象と判定されない")
        }
    }

    @Test("蔵書が置かれる普通の場所は対象外（三角の判定を止めない）")
    func ordinaryPlacesAreNotProtected() {
        for path in [home, home + "/Library", home + "/Documents",
                     "/Volumes/SomeDisk/Comics", "/Applications"] {
            #expect(!DirectoryProbe.isPrivacyProtected(URL(fileURLWithPath: path)),
                    "\(path) を誤って保護対象にしている")
        }
    }

    @Test("名前が前方一致するだけの別フォルダを巻き込まない")
    func siblingWithSharedPrefixIsNotProtected() {
        // `Mail` に対する `MailBackup`、`Containers` に対する `ContainersOld`。
        // 素の `hasPrefix` だと巻き込む——成分の境界で判定する必要がある。
        #expect(!DirectoryProbe.isPrivacyProtected(
            URL(fileURLWithPath: home + "/Library/MailBackup")))
        #expect(!DirectoryProbe.isPrivacyProtected(
            URL(fileURLWithPath: home + "/Library/ContainersOld")))
    }

    @Test("保護対象は読みに行かない（`nil` を返して三角は出したままにする）")
    func protectedPathsAreNotProbed() {
        // **`nil` が要点**——`false` にすると三角が消え、実際には中身がある
        // フォルダを開けなくなる。判定できないときは安全側（出す）に倒す。
        let result = DirectoryProbe.hasSubdirectory(
            at: URL(fileURLWithPath: home + "/Library/Containers"))
        #expect(result == nil)
    }
}

@Suite("配下の集計 [DT-05][DT-06]")
struct DirectoryProbeCountingTests {

    private func makeTree() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qoo-counts-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("sub/deep"),
                               withIntermediateDirectories: true)
        fm.createFile(atPath: base.appendingPathComponent("a.txt").path,
                      contents: Data(repeating: 0x41, count: 10))
        fm.createFile(atPath: base.appendingPathComponent("sub/b.txt").path,
                      contents: Data(repeating: 0x42, count: 20))
        fm.createFile(atPath: base.appendingPathComponent("sub/deep/c.txt").path,
                      contents: Data(repeating: 0x43, count: 30))
        return base
    }

    @Test("配下を再帰的に数える [DT-05][DT-06]")
    func countsRecursively() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let counts = try #require(DirectoryProbe.containedCounts(at: base))
        #expect(counts.fileCount == 3)
        #expect(counts.folderCount == 2)      // sub, sub/deep
        #expect(counts.totalSize == 60)
    }

    @Test("読めない場所では 0 件を返す（失敗と空を取り違えない）")
    func unreadableYieldsZero() {
        let counts = DirectoryProbe.containedCounts(
            at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(counts?.fileCount == 0)
        #expect(counts?.folderCount == 0)
    }

    @Test("打ち切られたら `nil`（途中まで数えた値を返さない）")
    func cancellationYieldsNil() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        // **途中の値を返すと、呼び出し側がそれを確定値として表示する**
        // [レビューで発見]。「3 ファイル」と出ているのに実は数え途中、
        // という状態を画面から見分けられない。
        let flag = Cancellation.Flag()
        flag.request()
        let result: DirectoryProbe.ContainedCounts? = Cancellation.withScope(flag) {
            DirectoryProbe.containedCounts(at: base)
        }
        #expect(result == nil)
    }

    @Test("プライバシー保護された場所へは降りない（数だけ 1 と数える）")
    func doesNotDescendIntoProtectedPlaces() throws {
        // `~/Library` を数えると、保護対象（Containers・CloudStorage・Mail 等）に
        // **降りずに**通り過ぎる。降りると TCC の許可ダイアログが次々に出る
        // ——フォルダを選んだだけで、である［ユーザー報告で発覚］。
        guard let pw = getpwuid(getuid()) else { return }
        let library = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir) + "/Library")
        guard FileManager.default.fileExists(atPath: library.path) else { return }

        // **起点そのものが保護対象の場合**——中へは降りない。
        let containers = library.appendingPathComponent("Containers")
        guard FileManager.default.fileExists(atPath: containers.path) else { return }
        let direct = try #require(DirectoryProbe.containedCounts(at: containers))
        #expect(direct.fileCount == 0)
        #expect(direct.folderCount == 0)

        // **列挙中に保護対象へ出会う場合**——`~/Library` を起点にすると
        // `Containers`（実測 741 フォルダ）・`CloudStorage`・`Mail` 等に出会う。
        // 降りなければ、それらは 1 フォルダとしてだけ数えられる。
        //
        // **この標本でないと、列挙中のガードを一度も通らない**——起点の検査が
        // 先に効いてしまうため（変異検証で 2 件空振りして分かった）。
        // **絶対値の閾値では判定できない**（`~/Library` は保護対象を除いても
        // 実測 1 万フォルダある）。素の再帰列挙と突き合わせて、**保護対象の
        // 配下ぶんが確かに引かれている**ことで判定する。
        let whole = try #require(DirectoryProbe.containedCounts(at: library))
        var naive = 0
        if let e = FileManager.default.enumerator(at: library,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true {
                naive += 1
            }
        }
        // `Containers` だけで実測 741 フォルダあるので、差は十分に大きい。
        #expect(whole.folderCount < naive,
                "保護対象の配下へ降りている（素の列挙と同数になっている）")
    }
}
