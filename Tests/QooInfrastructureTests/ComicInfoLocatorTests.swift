import Foundation
import Testing

@testable import QooInfrastructure
@testable import QooKit

/// アーカイブ内で `ComicInfo.xml` をどこまで探すか [EM-20][EM-21]。
@Suite struct ComicInfoLocatorTests {

    private func listing(_ paths: [String], directories: [String] = []) -> ArchiveListing {
        var entries = paths.map {
            ArchiveEntry(pathname: $0, uncompressedSize: 100, isDirectory: false, isSymlink: false)
        }
        entries += directories.map {
            ArchiveEntry(pathname: $0, uncompressedSize: 0, isDirectory: true, isSymlink: false)
        }
        return ArchiveListing(entries: entries)
    }

    @Test func findsItAtTheArchiveRoot() {
        let found = ComicInfoLocator.find(in: listing(["ComicInfo.xml", "001.jpg", "002.jpg"]))
        #expect(found?.pathname == "ComicInfo.xml")
    }

    @Test func findsNothingWhenThereIsNone() {
        #expect(ComicInfoLocator.find(in: listing(["001.jpg", "002.jpg"])) == nil)
    }

    /// 仕様は `ComicInfo.xml` を要求するが、小文字で書き出すツールが実在する [EM-21]。
    @Test func matchesCaseInsensitively() {
        let found = ComicInfoLocator.find(in: listing(["comicinfo.xml", "001.jpg"]))
        #expect(found?.pathname == "comicinfo.xml")
    }

    /// 両方あるなら、仕様どおりの綴りのほうが意図して置かれた可能性が高い。
    @Test func prefersTheCanonicalSpellingWhenBothExist() {
        let found = ComicInfoLocator.find(in: listing(["comicinfo.xml", "ComicInfo.xml", "001.jpg"]))
        #expect(found?.pathname == "ComicInfo.xml")
    }

    /// `作品名/ComicInfo.xml` という構造は実際に多い [EM-20]。
    @Test func looksInsideASingleTopLevelFolder() {
        let found = ComicInfoLocator.find(in: listing(
            ["作品名A/ComicInfo.xml", "作品名A/001.jpg", "作品名A/002.jpg"],
            directories: ["作品名A/"]))
        #expect(found?.pathname == "作品名A/ComicInfo.xml")
    }

    /// **トップレベルの項目が 2 つ以上あるなら、どれが本体か決められない。**
    /// 複数巻をまとめたアーカイブで誤った巻数を拾うより、読まないほうが害が小さい。
    @Test func refusesToGuessWhenThereAreSeveralTopLevelFolders() {
        let found = ComicInfoLocator.find(in: listing([
            "第1巻/ComicInfo.xml", "第1巻/001.jpg",
            "第2巻/ComicInfo.xml", "第2巻/001.jpg",
        ]))
        #expect(found == nil)
    }

    @Test func aFileAtTheRootMeansTheArchiveIsNotWrappedInOneFolder() {
        let found = ComicInfoLocator.find(in: listing(["読んでね.txt", "作品名A/ComicInfo.xml"]))
        #expect(found == nil)
    }

    /// ルート直下にあれば、包まれたものより優先する。
    @Test func prefersTheRootOverANestedOne() {
        let found = ComicInfoLocator.find(in: listing(
            ["ComicInfo.xml", "作品名A/ComicInfo.xml", "作品名A/001.jpg"]))
        #expect(found?.pathname == "ComicInfo.xml")
    }

    /// 3 階層以上は見ない——そこまで潜ると、どの巻のものか判断できない。
    @Test func doesNotLookDeeperThanTwoLevels() {
        let found = ComicInfoLocator.find(in: listing(
            ["作品名A/中身/ComicInfo.xml", "作品名A/中身/001.jpg"]))
        #expect(found == nil)
    }

    /// ディレクトリエントリやシンボリックリンクは読み取りの対象にしない。
    @Test func ignoresDirectoryAndSymlinkEntries() {
        let entries = [
            ArchiveEntry(pathname: "ComicInfo.xml", uncompressedSize: 0, isDirectory: true, isSymlink: false),
            ArchiveEntry(pathname: "comicinfo.xml", uncompressedSize: 0, isDirectory: false, isSymlink: true),
        ]
        #expect(ComicInfoLocator.find(in: ArchiveListing(entries: entries)) == nil)
    }
}
