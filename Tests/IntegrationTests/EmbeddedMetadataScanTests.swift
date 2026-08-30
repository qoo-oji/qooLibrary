import Foundation
import QooKit
import Testing

@testable import QooInfrastructure
@testable import QooPersistence

//
//  埋め込みメタデータがスキャン経路で反映されることの統合テスト [EM-03][EM-07][EM-09]。
//
//  **形式ごとの読み取り（zip / EPUB / PDF）は `EmbeddedMetadataReaderTests` が
//  担保する。**ここで確かめるのは「スキャンの経路で DB に入るか」「キャッシュが
//  効くか」だけなので、標本は圧縮の要らないブックフォルダにしている。
//

/// 何回読まれたかを数えるフェイク。キャッシュが効いているかの観測に使う。
final class CountingMetadataReader: EmbeddedMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads: [String] = []
    private let stub: @Sendable (URL) -> EmbeddedMetadata?

    init(stub: @escaping @Sendable (URL) -> EmbeddedMetadata?) { self.stub = stub }

    var reads: [String] { lock.lock(); defer { lock.unlock() }; return _reads }
    var readCount: Int { reads.count }

    /// **`NSLock.lock()` は async 関数の本体から呼べない**（`noasync`）ので、
    /// 記録は同期のヘルパーへ退避する [CLAUDE.md の既知の罠]。
    private func record(_ name: String) {
        lock.lock(); _reads.append(name); lock.unlock()
    }

    func read(_ url: URL, kind: PreviewableFileKind,
              volumeSource: ComicInfoVolumeSource) async -> EmbeddedMetadata? {
        record(url.lastPathComponent)
        return stub(url)
    }
}

/// `@Sendable` なクロージャから読み書きする箱。
final class Evicted: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

@Suite(.serialized) struct EmbeddedMetadataScanTests {

    /// 巻数を扱うテストで使うテンプレート。
    ///
    /// **同人誌(A) は巻数フォーマットを持たない**（`VS-Doujin`）ので、
    /// 「ファイル名から巻数が取れている」ことを前提にした検証はそちらでは
    /// 成立しない——一般コミック(A)（`VS-Full`）を使う。フォーマットは
    /// `(@booktype) [@author] @title` で、意味束縛は `@series: 2` / `@author: 1`。
    private static let comicPreset = "builtin.general-comic-a"

    /// 一般コミック(A) のフォーマットに一致する名前。
    private func comicName(_ title: String, author: String = "著者値A") -> String {
        "(一般コミック) [\(author)] \(title)"
    }

    /// ブックフォルダ（直下に画像だけを持つフォルダ）を作る [IF-01]。
    private func makeBookFolder(_ workspace: ScanWorkspace, _ name: String,
                                comicInfo: String? = nil) throws {
        try workspace.write("\(name)/001.jpg")
        try workspace.write("\(name)/002.jpg")
        if let comicInfo {
            let url = workspace.root.appendingPathComponent("\(name)/ComicInfo.xml")
            try Data(comicInfo.utf8).write(to: url)
        }
    }

    private func comicInfo(title: String = "メタの題", series: String = "メタのシリーズ",
                           number: String? = "3", volume: String? = nil,
                           writer: String = "メタの著者") -> String {
        var body = "<?xml version=\"1.0\"?>\n<ComicInfo>\n  <Title>\(title)</Title>\n"
        body += "  <Series>\(series)</Series>\n"
        if let number { body += "  <Number>\(number)</Number>\n" }
        if let volume { body += "  <Volume>\(volume)</Volume>\n" }
        body += "  <Writer>\(writer)</Writer>\n</ComicInfo>"
        return body
    }

    private func row(_ w: ScanWorkspace, _ relativePath: String) async throws -> FileRow? {
        let page = try await w.files.query(FileQuery(libraryID: w.libraryID, limit: 500))
        return page.rows.first { $0.relativePath == relativePath }
    }

    // MARK: - 反映

    @Test func metadataFromABookFolderLandsInTheDatabase() async throws {
        let w = try await ScanWorkspace()
        try makeBookFolder(w, "作品名A", comicInfo: comicInfo())
        let summary = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(summary.added == 1)

        let file = try #require(await row(w, "作品名A"))
        #expect(file.title == "メタの題")
        #expect(file.seriesName == "メタのシリーズ")
        #expect(file.volume == .numeric(3, raw: "3"))
    }

    /// [EM-03] メタデータはファイル名から抽出した値より優先する。
    @Test func metadataWinsOverTheFilename() async throws {
        let w = try await ScanWorkspace(preset: Self.comicPreset)
        // フォルダ名からは「作品名B」「第09巻」と読めるが、メタデータが上書きする。
        let name = comicName("作品名B 第09巻")
        try makeBookFolder(w, name, comicInfo: comicInfo(series: "メタのシリーズ", number: "3"))
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        let file = try #require(await row(w, name))
        #expect(file.seriesName == "メタのシリーズ")
        #expect(file.volume == .numeric(3, raw: "3"))
    }

    /// [EM-04] メタデータが持たないフィールドはファイル名由来の値を残す。
    @Test func fieldsTheMetadataLacksKeepTheFilenameValue() async throws {
        let w = try await ScanWorkspace(preset: Self.comicPreset)
        // `Series` だけを持つ ComicInfo。巻数はフォルダ名から読めているはず。
        let partial = "<?xml version=\"1.0\"?><ComicInfo><Series>メタのシリーズ</Series></ComicInfo>"
        let name = comicName("作品名C 第09巻")
        try makeBookFolder(w, name, comicInfo: partial)
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        let file = try #require(await row(w, name))
        #expect(file.seriesName == "メタのシリーズ")
        #expect(file.volume == .numeric(9, raw: "第09巻"))   // ファイル名から
    }

    @Test func aFolderWithoutMetadataIsUnaffected() async throws {
        let w = try await ScanWorkspace(preset: Self.comicPreset)
        let name = comicName("作品名D 第02巻")
        try makeBookFolder(w, name)
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        let file = try #require(await row(w, name))
        #expect(file.volume == .numeric(2, raw: "第02巻"))
        #expect(file.seriesName == "作品名D")
    }

    // MARK: - キャッシュ [EM-07][SE3-25]

    /// **2 回目のスキャンでファイルを開かない。**これがスキャンを実用的な速さに
    /// 保つ唯一の手段で、無いと再スキャンのたびに 5 万件を開き直す。
    @Test func aSecondScanDoesNotReopenUnchangedFiles() async throws {
        let reader = CountingMetadataReader { _ in
            EmbeddedMetadata(source: .comicInfo, title: "メタの題")
        }
        let w = try await ScanWorkspace(metadata: reader)
        try makeBookFolder(w, "作品名A")
        try makeBookFolder(w, "作品名B")

        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 2)

        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 2)     // 増えない
    }

    /// **メタデータを持たないファイルでも印を書く** [SE3-25]。書かないと
    /// 「まだ読んでいない」と区別できず、毎回開き直すことになる。
    @Test func filesWithoutMetadataAreAlsoRemembered() async throws {
        let reader = CountingMetadataReader { _ in nil }      // 常に「持っていない」
        let w = try await ScanWorkspace(metadata: reader)
        try makeBookFolder(w, "作品名A")

        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 1)
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 1)     // 増えない
    }

    @Test func changingTheFileMakesItReadAgain() async throws {
        let reader = CountingMetadataReader { _ in
            EmbeddedMetadata(source: .comicInfo, title: "メタの題")
        }
        let w = try await ScanWorkspace(metadata: reader)
        try makeBookFolder(w, "作品名A")
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 1)

        // 中身を足すとフォルダの更新日時が変わる → 印が変わる → 読み直す。
        try w.write("作品名A/003.jpg")
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 2)
    }

    /// [EM-06] 設定を切ったら 1 件も開かない。
    @Test func theLibrarySettingTurnsReadingOff() async throws {
        let reader = CountingMetadataReader { _ in
            EmbeddedMetadata(source: .comicInfo, title: "メタの題")
        }
        let w = try await ScanWorkspace(preset: Self.comicPreset, metadata: reader,
                                        readsEmbeddedMetadata: false)
        let name = comicName("作品名A 第02巻")
        try makeBookFolder(w, name)
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        #expect(reader.readCount == 0)
        let file = try #require(await row(w, name))
        #expect(file.volume == .numeric(2, raw: "第02巻"))   // ファイル名由来のまま
    }

    /// [EM-01] 画像や動画そのものは `ComicInfo.xml` を持てない——開くだけ無駄。
    @Test func doesNotOpenKindsThatCannotCarryMetadata() async throws {
        let reader = CountingMetadataReader { _ in nil }
        let w = try await ScanWorkspace(targetExtensions: ["cbz", "jpg", "mp4"], metadata: reader)
        try w.write("画像A.jpg")
        try w.write("動画A.mp4")
        try w.write("書庫A.cbz")
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        #expect(reader.reads == ["書庫A.cbz"])
    }

    /// [EM-62] クラウドから追い出された実体は読まない。
    ///
    /// **読むとダウンロードが走る。**一覧を開いただけで蔵書全体の実体化が
    /// 始まってしまう——サムネイル生成が同じ理由で避けているのと同じ判断。
    @Test func doesNotMaterializeFilesThatLiveOnlyInTheCloud() async throws {
        let reader = CountingMetadataReader { _ in
            EmbeddedMetadata(source: .comicInfo, title: "メタの題")
        }
        let w = try await ScanWorkspace(metadata: reader, isDataless: { _ in true })
        try makeBookFolder(w, "作品名A")
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        #expect(reader.readCount == 0)
    }

    /// dataless なファイルには**印を書かない**——実体が戻ってきたら読めるように
    /// しておく必要がある。「読んだが無かった」と混同してはならない。
    @Test func aDatalessFileIsRetriedOnceItComesBack() async throws {
        let reader = CountingMetadataReader { _ in
            EmbeddedMetadata(source: .comicInfo, title: "メタの題")
        }
        let evicted = Evicted()
        let w = try await ScanWorkspace(metadata: reader,
                                        isDataless: { _ in evicted.value })
        try makeBookFolder(w, "作品名A")

        evicted.value = true
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 0)

        evicted.value = false           // 実体が戻ってきた
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(reader.readCount == 1)
    }

    // MARK: - 巻数の衝突 [EM-26][EM-31]

    @Test func aVolumeConflictIsCountedAndRecordedWithoutStoppingTheScan() async throws {
        let w = try await ScanWorkspace(preset: Self.comicPreset)
        let conflicted = comicName("作品名A 第09巻")
        try makeBookFolder(w, conflicted, comicInfo: comicInfo(number: "12", volume: "2"))
        try makeBookFolder(w, comicName("作品名B 第03巻"))

        let summary = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(summary.added == 2)                 // 止まらない [EM-31]
        #expect(summary.volumeConflicts == 1)

        // [EM-34] 判断が済むまでは、巻数はファイル名から抽出した値を使う。
        let file = try #require(await row(w, conflicted))
        #expect(file.volume == .numeric(9, raw: "第09巻"))
        #expect(file.seriesName == "メタのシリーズ")   // 他のフィールドは上書きする

        let pending = try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID)
        #expect(pending.count == 1)
        #expect(pending.first?.filename == conflicted)
        #expect(pending.first?.conflict.number == 12)
        #expect(pending.first?.conflict.volume == 2)
    }

    /// [EM-30] ライブラリ設定で決めてあれば聞かない。
    @Test func aSettledLibrarySettingResolvesConflictsSilently() async throws {
        let w = try await ScanWorkspace(preset: Self.comicPreset)
        var draft = try #require(try await w.libraries.settingsDraft(libraryID: w.libraryID))
        draft.comicInfoVolumeSource = .volume
        try await w.libraries.updateSettings(draft, libraryID: w.libraryID)

        let name = comicName("作品名A 第09巻")
        try makeBookFolder(w, name, comicInfo: comicInfo(number: "12", volume: "2"))
        let summary = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        #expect(summary.volumeConflicts == 0)
        let file = try #require(await row(w, name))
        #expect(file.volume == .numeric(2, raw: "2"))
        #expect(try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID).isEmpty)
    }

    // MARK: - ラベル [EMM-03]

    /// 意味束縛でラベルグループへ流している著者は、ラベル側もメタデータに揃える。
    @Test func theAuthorLabelFollowsTheMetadata() async throws {
        // 同人誌(A) のテンプレートは著者を `@author` として取り、意味束縛で
        // ラベルグループへ流す [RW-13]。
        let w = try await ScanWorkspace()
        try makeBookFolder(w, "(同人誌) [サークル値A (ファイル名の著者)] 作品名A",
                           comicInfo: comicInfo(writer: "メタの著者A, メタの著者B"))
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)

        let circle = try #require(try await w.field(.circle))
        let author = try #require(try await w.field(.author))
        let authorNames = Set(try await w.labels.labels(groupID: author.id, includeArchived: true)
            .map(\.name))
        #expect(authorNames.contains("メタの著者A"))
        #expect(authorNames.contains("メタの著者B"))
        // グループごと置き換えるので、ファイル名由来の著者はこのファイルには付かない。
        let file = try #require(await row(w, "(同人誌) [サークル値A (ファイル名の著者)] 作品名A"))
        let assigned = try await w.labels.labelIDs(fileID: file.id).map(\.labelID)
        let assignedNames = Set(try await w.labels.labels(groupID: author.id, includeArchived: true)
            .filter { assigned.contains($0.id) }.map(\.name))
        #expect(assignedNames == ["メタの著者A", "メタの著者B"])
        // 他のグループは触らない。
        #expect(try await w.labels.labels(groupID: circle.id, includeArchived: true)
            .map(\.name) == ["サークル値A"])
    }
}

/// 巻数の判断を確定する経路 [EM-33]。
@Suite(.serialized) struct VolumeDecisionTests {

    private func workspace() async throws -> (ScanWorkspace, String) {
        let w = try await ScanWorkspace(preset: "builtin.general-comic-a")
        let name = "(一般コミック) [著者値A] 作品名A 第09巻"
        try w.write("\(name)/001.jpg")
        try w.write("\(name)/002.jpg")
        let xml = """
        <?xml version="1.0"?><ComicInfo><Series>メタのシリーズ</Series>
        <Number>12</Number><Volume>2</Volume></ComicInfo>
        """
        try Data(xml.utf8).write(to: w.root.appendingPathComponent("\(name)/ComicInfo.xml"))
        _ = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        return (w, name)
    }

    private func row(_ w: ScanWorkspace, _ relativePath: String) async throws -> FileRow? {
        let page = try await w.files.query(FileQuery(libraryID: w.libraryID, limit: 500))
        return page.rows.first { $0.relativePath == relativePath }
    }

    @Test(arguments: [(ComicInfoVolumeSource.number, 12.0, "12"),
                      (.volume, 2.0, "2")])
    func choosingASideWritesThatVolume(source: ComicInfoVolumeSource,
                                       expected: Double, raw: String) async throws {
        let (w, name) = try await workspace()
        let pending = try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID)
        #expect(pending.count == 1)

        try await w.files.resolveVolumeConflicts(pending.map(\.id), using: source)

        let file = try #require(await row(w, name))
        #expect(file.volume == .numeric(expected, raw: raw))
        #expect(try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID).isEmpty)
    }

    /// **再スキャンしても判断が覆らない。** 判断の結果をメタデータ側にも
    /// 残さないと、印が一致する限り衝突のままに見える。
    @Test func theDecisionSurvivesARescan() async throws {
        let (w, name) = try await workspace()
        let pending = try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID)
        try await w.files.resolveVolumeConflicts(pending.map(\.id), using: .volume)

        let summary = try await w.engine.scan(.full(libraryID: w.libraryID), root: w.root)
        #expect(summary.volumeConflicts == 0)
        let file = try #require(await row(w, name))
        #expect(file.volume == .numeric(2, raw: "2"))
    }

    /// `.ask` は「まだ決めていない」という意味なので、何も書かない。
    @Test func askIsNotADecision() async throws {
        let (w, _) = try await workspace()
        let pending = try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID)
        try await w.files.resolveVolumeConflicts(pending.map(\.id), using: .ask)
        #expect(try await w.files.filesAwaitingVolumeDecision(libraryID: w.libraryID).count == 1)
    }
}
