import Foundation
import QooKit
import Testing
@testable import QooInfrastructure
@testable import QooPersistence

//
//  差分スキャンの統合テスト [SY-03][SY-04][SY-12][ID-06]。
//
//  **結線前は `.incremental` が差分パスを一切使わず、ライブラリ全体を列挙して
//  いた**（ファイルが 1 つ変わるたびに 5 万件の走査）。ここで固定するのは
//  「範囲が絞られること」と「絞ったせいで取りこぼさないこと」の両方。
//

@Suite("差分スキャン [SY-03][SY-04][ID-06]", .serialized)
struct IncrementalScanTests {

    func incremental(_ w: ScanWorkspace, _ paths: [String]) async throws -> ScanSummary {
        try await w.engine.scan(.incremental(libraryID: w.libraryID, paths: paths), root: w.root)
    }

    // MARK: - 範囲が絞られる [SY-03]

    /// **この 1 件がこの作業の主目的。** 単位数が 1 で、しかも根の再帰ではない
    /// ことを確かめる——`scannedUnits` は「見た場所の数」で、全体列挙へ落ちて
    /// いれば根の再帰 1 単位になるので、件数だけでは区別できない。
    @Test("1 ファイルの変更で、その親だけを見る")
    func oneFileChangeScansOnlyItsParent() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 既存.cbz")
        try w.write("作者B/[サークルB] 無関係.cbz")
        _ = try await w.scanFull()

        try w.write("作者A/[サークルC] 新しい.cbz")
        let summary = try await incremental(w, ["作者A/[サークルC] 新しい.cbz"])

        #expect(summary.added == 1)
        // 作者B は見ていないので「更新」に数えられない。全体列挙なら 2 になる。
        #expect(summary.updated == 1, "見たのは 作者A の直下だけのはず")
        #expect(summary.orphaned == 0, "見ていない範囲を孤立にしてはならない")
        let rows = try await w.rows()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.state == .active })
    }

    @Test("複数のフォルダで変更があれば、その数だけ見る")
    func severalFoldersProduceSeveralUnits() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 1.cbz")
        try w.write("作者B/[サークルB] 2.cbz")
        try w.write("作者C/[サークルC] 3.cbz")
        _ = try await w.scanFull()

        let summary = try await incremental(
            w, ["作者A/[サークルA] 1.cbz", "作者B/[サークルB] 2.cbz"])
        #expect(summary.scannedUnits == 2)
        #expect(summary.updated == 2, "作者C は見ていない")
    }

    /// **フォルダごと移動されてきた場合、中のファイルは 1 件も報告されない。**
    /// 親を非再帰で見ると中身が 1 件も DB に載らない。
    @Test("フォルダが丸ごと現れたら、その中を再帰で取り込む")
    func aNewDirectoryIsScannedRecursively() async throws {
        let w = try await ScanWorkspace()
        try w.write("既存/[サークルA] 1.cbz")
        _ = try await w.scanFull()

        try w.write("新入り/深い/[サークルB] 2.cbz")
        try w.write("新入り/[サークルC] 3.cbz")
        // FSEvents はフォルダのパスだけを報告する
        let summary = try await incremental(w, ["新入り"])

        #expect(summary.added == 2, "中身を再帰で取り込むべき")
        let rows = try await w.rows()
        #expect(rows.count == 3)
    }

    // MARK: - 削除が反映される [ID-06]

    /// **以前は差分スキャンが孤立の判定を丸ごと飛ばしていた**ので、外部で
    /// 削除されたファイルが `active` のまま残り続けた。
    @Test("外部で削除されたファイルが孤立になる [ID-06]")
    func anExternallyDeletedFileBecomesOrphaned() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 消える.cbz")
        try w.write("作者A/[サークルB] 残る.cbz")
        _ = try await w.scanFull()

        // **FSEvents が渡してくる形**（ディスク上の綴り）で渡す。
        let changed = try w.onDiskRelativePath("作者A/[サークルA] 消える.cbz")
        try w.remove("作者A/[サークルA] 消える.cbz")
        let summary = try await incremental(w, [changed])

        #expect(summary.orphaned == 1)
        let rows = try await w.allRows()
        #expect(rows.first { $0.path.contains("消える") }?.state == .orphaned)
        #expect(rows.first { $0.path.contains("残る") }?.state == .active)
    }

    /// 消えたのがフォルダなら、**中身は親の「直下だけ」の照合では拾えない**。
    @Test("外部で削除されたフォルダは、中身もまとめて孤立になる [ID-06]")
    func anExternallyDeletedDirectoryOrphansItsContents() async throws {
        let w = try await ScanWorkspace()
        try w.write("消えるフォルダ/深い/[サークルA] 1.cbz")
        try w.write("消えるフォルダ/[サークルB] 2.cbz")
        try w.write("残るフォルダ/[サークルC] 3.cbz")
        _ = try await w.scanFull()

        // **消えたパスは `realpath` で綴りを揃えられない**（情報がファイルと
        // 一緒に消えている）ので、消す前にディスク上の綴りを控えておく。
        // これは FSEvents が実際に渡してくる形でもある。
        let changed = try w.onDiskRelativePath("消えるフォルダ")
        try w.remove("消えるフォルダ")
        let summary = try await incremental(w, [changed])

        #expect(summary.orphaned == 2)
        let rows = try await w.allRows()
        #expect(rows.first { $0.path.contains("3") }?.state == .active,
                "無関係なフォルダを巻き添えにしてはならない")
        #expect(rows.count { $0.state == .orphaned } == 2)
    }

    /// **見ていない範囲を孤立にしない**——これを壊すと、ファイルが 1 つ変わる
    /// たびにライブラリ全体のラベルと評価が飛ぶ [R-01][SB-05]。
    @Test("差分の範囲外は孤立にしない")
    func filesOutsideTheScopeAreNeverOrphaned() async throws {
        let w = try await ScanWorkspace()
        for i in 0..<5 { try w.write("作者\(i)/[サークル\(i)] 作品.cbz") }
        _ = try await w.scanFull()

        // 作者0 の中だけを差分で見る。他の 4 件は実体があるが列挙していない。
        try w.write("作者0/[サークルX] 追加.cbz")
        let summary = try await incremental(w, ["作者0/[サークルX] 追加.cbz"])

        #expect(summary.orphaned == 0)
        let rows = try await w.rows()
        #expect(rows.count { $0.state == .active } == 6)
    }

    // MARK: - ディスク上の綴りへ揃える [実測]

    /// **正規化が 1 文字違うだけで、孤立の照合（SQLite の `LIKE`）が
    /// 1 件も一致しなくなる。** `contentsOfDirectory` は濁点を NFD で返す
    /// 一方、アプリが自分で組み立てたパスは NFC のことがある。
    /// `realpath(3)` を通してディスク上の綴りへ揃えることで塞いである。
    @Test("NFC で綴られた変更パスでも、範囲が正しく絞られる")
    func aChangedPathSpelledInNFCStillScopesCorrectly() async throws {
        let w = try await ScanWorkspace()
        try w.write("フォルダ/[サークルA] 消える.cbz")
        try w.write("フォルダ/[サークルB] 残る.cbz")
        _ = try await w.scanFull()

        // ディスク上は NFD（U+30BF U+3099）。**NFC の綴りで要求する。**
        let nfc = "フォルダ/[サークルA] 消える.cbz".precomposedStringWithCanonicalMapping
        #expect(nfc.unicodeScalars.contains(Unicode.Scalar(0x30C0)!), "標本が NFC であること")
        try w.remove("フォルダ/[サークルA] 消える.cbz")

        let summary = try await incremental(w, [nfc])
        #expect(summary.orphaned == 1, "綴りを揃えないと 0 件になる")
        let rows = try await w.allRows()
        #expect(rows.first { $0.path.contains("残る") }?.state == .active)
    }

    // MARK: - フルスキャンへの落とし方 [SY-04]

    @Test("変更が多すぎるとフルスキャンへ落ちる [SY-04]")
    func tooManyChangesFallBackToFullScan() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 1.cbz")
        _ = try await w.scanFull()

        let paths = (0..<200).map { "作者\($0)/作品.cbz" }
        let summary = try await incremental(w, paths)
        #expect(summary.scannedUnits == 1, "根を 1 単位で見る＝フルスキャン")
        #expect(summary.updated == 1)
    }

    @Test("変更のパスが分からない差分要求はフルスキャンと同じ [SY-04]")
    func anEmptyIncrementalRequestScansEverything() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 1.cbz")
        try w.write("作者B/[サークルB] 2.cbz")
        _ = try await w.scanFull()

        let summary = try await incremental(w, [])
        #expect(summary.updated == 2)
    }

    // MARK: - 冪等 [FO-20][SY-12]

    @Test("差分スキャンも冪等 [FO-20][SY-12]")
    func incrementalScanIsIdempotent() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 1.cbz")
        _ = try await w.scanFull()

        let first = try await incremental(w, ["作者A/[サークルA] 1.cbz"])
        let second = try await incremental(w, ["作者A/[サークルA] 1.cbz"])
        #expect(first.added == 0 && first.updated == 1)
        #expect(second.added == 0 && second.updated == 1)
        #expect(second.orphaned == 0)
    }

    /// オフラインなら差分でも走らせない [SB-05][ID-08][R-01]。
    @Test("オフラインのライブラリは差分でも走査しない [SB-05]")
    func offlineLibraryIsNotScannedIncrementally() async throws {
        let w = try await ScanWorkspace()
        try w.write("作者A/[サークルA] 1.cbz")
        _ = try await w.scanFull()
        try await w.libraries.setOnline(false, libraryID: w.libraryID)

        let summary = try await incremental(w, ["作者A/[サークルA] 1.cbz"])
        #expect(summary.skipped)
        #expect(summary.orphaned == 0)
    }
}
