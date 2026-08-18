import Foundation
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
