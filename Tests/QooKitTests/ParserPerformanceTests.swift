import Testing
import Foundation
@testable import QooKit

//
//  T-05: ネスト構造を含むファイル名フォーマットのパーサを、正規表現ではなく
//  構文木で実装した場合の性能（1 万ファイル × 50 フォーマット）。
//
//  仕様書 §4.7.1 は「前方アンカー → 後方アンカー → 中央のバックトラッキング」の
//  3 段構成を挙げているが、実装は段を分けていない [設計判断]。検証器が
//  「自由文字列フィールドの隣は必ず境界」を保証する [FF-18][VD-02] ため、
//  素直な再帰でも自由文字列の走査は「次の境界を探す」だけになるという読み。
//  **その読みが正しいかをここで測る。**
//

/// 実コーパス（`Tests/GoldenDataset/private/corpus`、gitignore 済み）があれば
/// 実ファイル名を、無ければ実測した長さ分布に合わせた合成名を返す。
enum ParserBenchmarkCorpus {
    static let names: [String] = load()

    nonisolated(unsafe) static var realCount = 0

    static var corpusDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // QooKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Tests/GoldenDataset/private/corpus")
    }

    static func load() -> [String] {
        struct Corpus: Decodable {
            struct E: Decodable { let relativePath: String; let isDirectory: Bool }
            let entries: [E]
        }
        var out: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: corpusDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                guard let d = try? Data(contentsOf: f),
                      let c = try? JSONDecoder().decode(Corpus.self, from: d) else { continue }
                out += c.entries.filter { !$0.isDirectory }.map {
                    ($0.relativePath as NSString).lastPathComponent
                }
            }
        }
        realCount = out.count
        if out.count >= 200 { return out }
        // 合成: 実測した形（`(区分) [サークル (作家)] タイトル (原作)`、平均 46.6 文字）
        return (0..<2000).map { i in
            "(同人誌) [サークル\(i % 700) (作家\(i % 900))] 作品タイトルその\(i) 第\(i % 30 + 1)巻 (オリジナル)"
        }
    }
}

@Suite("T-05: パーサ性能（1 万ファイル × 50 フォーマット）", .serialized)
struct ParserPerformanceTests {

    /// 50 本のフォーマットを組む [FF-03]。
    ///
    /// **万能フォールバックの `@title` を外す。**入れたままだと大半のファイル名が
    /// 数本目で当たって終わり、「50 本を走査する」測定になっていなかった
    /// （実際にそうなっていて、一致率 100% で気づいた）。§6.1 の
    /// 「興味のあるケースだけ測って一般化した」に当たる。
    static func fiftyFormats() throws -> [CompiledFormat] {
        let ctxt = FormatCompilationContext(
            allLibraryTypeNames: ["一般コミック", "成年コミック", "同人誌", "同人CG"])
        var sources = PresetTemplateTests.allPresetFormats
            .flatMap(\.formats)
            .filter { $0 != "@title" }
        // 50 本になるまで、実在する形の変種で埋める（同人誌(B) / 同人CG(A) 相当）。
        let fillers = [
            "(@labelgroup1) [@labelgroup2 (@labelgroup3)] @title [@labelgroup4] (@labelgroup5)",
            "(@librarytype) (@labelgroup1) [@labelgroup2] @title",
            "[@labelgroup1] [@labelgroup2] @title",
            "[@labelgroup1] @title 【@labelgroup3】",
            "(@labelgroup1) @title",
            "[@labelgroup1] (@labelgroup2) @title",
            "(@librarytype) [@labelgroup1] @series (@volume)",
            "[@labelgroup1] @series (@volume)",
            "[@labelgroup1] @title (@volume)",
            "[@ignore] [@labelgroup1] @title",
            "[@labelgroup1] @title (@labelgroup2) (@labelgroup3)",
            "(@labelgroup1) [@labelgroup2] @title [@labelgroup3] (@labelgroup4)",
        ]
        var i = 0
        while sources.count < 50 { sources.append(fillers[i % fillers.count] + String(repeating: " ", count: i / fillers.count)); i += 1 }
        return try sources.prefix(50).enumerated().map { i, src in
            try FormatCompiler.compile(src, context: ctxt, priority: i)
        }
    }

    @Test("1 万ファイル × 50 フォーマットの照合が目標時間に収まる [PF-05][MT2-01]")
    func throughput() throws {
        let formats = try Self.fiftyFormats()
        let settings = LibrarySettingsSnapshot(
            libraryID: LibraryID(rawValue: 1),
            libraryTypeName: "同人誌",
            allLibraryTypeNames: ["一般コミック", "成年コミック", "同人誌", "同人CG"],
            filenameFormats: formats,
            volumeFormats: vsDoujin())
        let parser = FilenameParser()

        let pool = ParserBenchmarkCorpus.names
        let sampleCount = 10_000
        let samples = (0..<sampleCount).map { i -> String in
            let n = pool[i % pool.count]
            return (n as NSString).deletingPathExtension
        }

        var matched = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for name in samples {
            if parser.parse(name, settings: settings, purpose: .libraryScan) != nil { matched += 1 }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        let perFile = ms / Double(sampleCount)

        let source = ParserBenchmarkCorpus.realCount >= 200
            ? "実コーパス \(ParserBenchmarkCorpus.realCount) 件" : "合成"
        FileHandle.standardError.write(Data("""

        [T-05] フォーマット \(formats.count) 本 × \(sampleCount) 件（\(source)）
               合計 \(String(format: "%.0f", ms)) ms / 1 件あたり \(String(format: "%.3f", perFile)) ms
               一致 \(matched) 件（\(String(format: "%.1f", 100 * Double(matched) / Double(sampleCount)))%）
               ※ 一致率が 100% に近いなら、フォールバックが早く当たって
                  「50 本を走査する」測定になっていない可能性を疑うこと。

        """.utf8))

        // [MT2-01] 目標: 1 件あたり 50 フォーマットで 1ms 未満。
        // CI の遅いランナーでも通るよう、判定は 3 倍の余裕を見る。
        #expect(perFile < 3.0, "1 件あたり \(perFile) ms（目標 1 ms、判定 3 ms）")
        // [PF-05] 1 万ファイルのフルスキャン 60 秒のうち、照合はごく一部で済むこと。
        #expect(ms < 10_000, "1 万件で \(ms) ms")
    }

    @Test("一致しないファイル名（最悪ケース: 全 50 フォーマットを試して全滅）")
    func worstCaseNoMatch() throws {
        let formats = try Self.fiftyFormats()
        let settings = LibrarySettingsSnapshot(
            libraryID: LibraryID(rawValue: 1),
            libraryTypeName: "同人誌",
            allLibraryTypeNames: ["一般コミック", "同人誌"],
            filenameFormats: formats,
            volumeFormats: vsDoujin())
        let parser = FilenameParser()

        // 括弧を大量に含み、どのフォーマットにも一致しない病的な入力。
        let pathological = String(repeating: "[a(b)c] ", count: 12) + "終わり"
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 {
            _ = parser.parse(pathological, settings: settings, purpose: .libraryScan)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 / 200
        FileHandle.standardError.write(Data(
            "[T-05] 最悪ケース（\(pathological.count) 文字・全滅）: \(String(format: "%.3f", ms)) ms/件\n".utf8))
        #expect(ms < 30.0)
    }

    /// 病的なフォーマットで停止しなくなるのを防ぐ関門 [MT2-02]。
    @Test("探索ノード数の上限で打ち切る [MT2-02]")
    func stepLimitStopsRunaway() throws {
        let ctxt = FormatCompilationContext()
        // 自由文字列を境界で細かく区切った、探索の広いフォーマット
        let f = try FormatCompiler.compile(
            "[@labelgroup1] [@labelgroup2] [@labelgroup3] [@labelgroup4] @title", context: ctxt)
        let input = ParseInput(String(repeating: "[あ] ", count: 40) + "末尾")
        let outcome = FormatMatcher.match(f, input: input, stepLimit: 500)
        #expect(outcome.steps <= 501)
        #expect(outcome.result == nil || outcome.exceededStepLimit == false)
    }
}
