import Foundation
import Testing
@testable import QooInfrastructure

//
//  変更パスをディスク上の綴りへ揃える [実測]。
//
//  **この層で直に試す。** 統合テスト側で確かめようとしたところ、SQLite の
//  `LIKE` が ASCII の大小文字を既定で畳むため、正規化をやめても通ってしまう
//  ——変異を当てて初めて「何も試していない」と分かった。
//
@Suite("走査パスの正規化 [SY-03]")
struct ScanPathCanonicalizationTests {

    /// 使い捨ての作業ディレクトリ。`realpath` を通すので実ファイルが要る。
    final class Workspace {
        let root: URL
        let canonicalRoot: String
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-canon-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            canonicalRoot = ScanEngine.canonicalPath(root.path) ?? root.path
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func makeDirectory(_ relative: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        func makeFile(_ relative: String) throws {
            try makeDirectory((relative as NSString).deletingLastPathComponent)
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(relative).path, contents: Data("x".utf8))
        }
        func canonical(_ relative: String) -> String {
            ScanEngine.canonicalRelativePath(relative, rootURL: root, canonicalRoot: canonicalRoot)
        }
        func onDiskName(in relative: String = "") throws -> String {
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(relative), includingPropertiesForKeys: nil)[0]
                .lastPathComponent
        }
    }

    /// **macOS は濁点を NFD で返す**（`フォルダ` は `フ ォ ル タ ゛`）。
    /// NFC の綴りで要求されても、ディスク上の綴りへ揃える。
    @Test("NFC の綴りをディスク上の NFD へ揃える")
    func foldsPrecomposedToWhatIsOnDisk() throws {
        let w = try Workspace()
        try w.makeDirectory("フォルダ")
        let onDisk = try w.onDiskName()
        #expect(onDisk.unicodeScalars.count == 5, "ディスク上は NFD のはず")

        let nfc = "フォルダ".precomposedStringWithCanonicalMapping
        #expect(nfc.unicodeScalars.count == 4, "標本が NFC であること")
        #expect(w.canonical(nfc) == onDisk)
    }

    @Test("大小文字もディスク上の綴りへ揃える")
    func foldsCaseToWhatIsOnDisk() throws {
        let w = try Workspace()
        try w.makeDirectory("Author")
        // 大小文字を区別するボリュームでは別物になるので、その場合は試さない。
        guard FileManager.default.fileExists(
            atPath: w.root.appendingPathComponent("AUTHOR").path) else { return }
        #expect(w.canonical("AUTHOR") == "Author")
    }

    /// **消えた末尾は揃えられない**（情報がファイルと一緒に消えている）が、
    /// **存在する祖先までは揃える**——これが無いと、削除の経路（いちばん
    /// 揃えたい場面）で毎回諦めることになる。
    @Test("末尾が消えていても、存在する祖先までは揃える")
    func foldsTheDeepestExistingAncestor() throws {
        let w = try Workspace()
        try w.makeDirectory("フォルダ")
        let onDisk = try w.onDiskName()
        let nfc = "フォルダ".precomposedStringWithCanonicalMapping

        let result = w.canonical("\(nfc)/消えたファイル.cbz")
        #expect(result == "\(onDisk)/消えたファイル.cbz")
    }

    @Test("何も存在しなければ元の綴りのまま返す")
    func keepsTheOriginalSpellingWhenNothingExists() throws {
        let w = try Workspace()
        #expect(w.canonical("無い/場所/x.cbz") == "無い/場所/x.cbz")
    }

    @Test("既にディスク上の綴りなら変わらない")
    func aPathAlreadyOnDiskIsUnchanged() throws {
        let w = try Workspace()
        try w.makeFile("作者A/作品.cbz")
        #expect(w.canonical("作者A/作品.cbz") == "作者A/作品.cbz")
    }

    // MARK: - パスの種別 [SY-03]

    @Test("ディレクトリ・ファイル・不在を見分ける")
    func classifiesPathKinds() throws {
        let w = try Workspace()
        try w.makeFile("作者A/作品.cbz")
        #expect(ScanEngine.pathKind(w.root.appendingPathComponent("作者A")) == .directory)
        #expect(ScanEngine.pathKind(w.root.appendingPathComponent("作者A/作品.cbz")) == .file)
        #expect(ScanEngine.pathKind(w.root.appendingPathComponent("無い")) == .absent)
    }

    /// **シンボリックリンクは走査の対象外** [SL-03] なので、リンク先まで辿って
    /// 「ディレクトリ」と答えてはいけない（`lstat` を使う理由）。
    @Test("ディレクトリへのシンボリックリンクはディレクトリと答えない [SL-03]")
    func aSymlinkToADirectoryIsNotADirectory() throws {
        let w = try Workspace()
        try w.makeDirectory("実体")
        try FileManager.default.createSymbolicLink(
            at: w.root.appendingPathComponent("リンク"),
            withDestinationURL: w.root.appendingPathComponent("実体"))
        #expect(ScanEngine.pathKind(w.root.appendingPathComponent("リンク")) == .file)
    }
}
