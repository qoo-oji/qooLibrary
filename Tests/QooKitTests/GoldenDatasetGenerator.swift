//
//  ゴールデンデータセットの生成 [GT-03][GT-05][MT-24][MT-27]。
//
//  `QOO_REGENERATE_GOLDEN=1 swift test --filter GoldenGenerator` で
//  `Tests/GoldenDataset/public/` を作り直す。
//
//  **public の期待値は実装の出力をそのまま写したものではない。**フォーマットへ
//  既知の値を差し込んで入力を組み立て、差し込んだ値をそのまま期待値にしている
//  ——つまり仕様から導いた答え合わせであって、現在の実装のスナップショットでは
//  ない。実装が壊れれば落ちる [GT-03]。
//
//  private（実ファイル名）は別経路。`Scripts/extract-golden-corpus.swift` で
//  取ったコーパスから作り、**期待値は現在の実装結果を初期値として人間が確認する**
//  [16章 §16.2 の収集の導線]。
//
import Foundation
import Testing
@testable import QooKit

enum GoldenGenerator {

    /// フォーマット文字列に既知の値を差し込んで入力を組み立てる。
    /// 予約語以外（区切り文字・リテラル・空白）は原文のまま残す。
    static func synthesize(format: String,
                           delimiters: DelimiterSet,
                           value: (FieldRef) -> String) throws -> String {
        var out = ""
        for token in try FormatLexer.lex(format, delimiters: delimiters) {
            switch token {
            case .literal(let s, _):        out += s
            case .whitespace:               out += " "
            case .separator(let sep, _):    out += sep.canonical
            case .pairOpen(let p, _):       out += String(p.open)
            case .pairClose(let p, _):      out += String(p.close)
            case .reservedWord(let f, _):   out += value(f)
            }
        }
        return out
    }

    /// 差し込む値。**区切り文字を含めない**（含めると入力の構造が変わってしまう）。
    struct Values {
        let template: LibraryTypeTemplate
        let variant: Int
        /// 巻数を付けるか（VS-None のプリセットでは付けない）。
        let withVolume: Bool

        var groupNames: [Int: String] {
            Dictionary(uniqueKeysWithValues: template.labelGroups.map { ($0.index, $0.name) })
        }

        /// 変種ごとに少しずつ違う形にする。実データで実際に出る揺れを混ぜる。
        var titleBody: String {
            switch variant % 5 {
            case 0: return "作品タイトル\(variant)"
            case 1: return "作品 タイトル \(variant)"                    // 内部に空白 [WS-05]
            case 2: return "作品タイトル\(variant)ー長音"                 // 長音を含む
            case 3: return "作品タイトル\(variant)".precomposedStringWithCanonicalMapping
            default: return "サブタイトル付き作品\(variant)"
            }
        }

        var volumeToken: String? {
            guard withVolume else { return nil }
            switch variant % 4 {
            case 0: return "第\(String(format: "%02d", variant % 30 + 1))巻"
            case 1: return "vol.\(variant % 30 + 1)"
            case 2: return "上巻"
            default: return nil                                          // 巻数なしも混ぜる
            }
        }

        var title: String {
            volumeToken.map { "\(titleBody) \($0)" } ?? titleBody
        }

        func callAsFunction(_ ref: FieldRef) -> String {
            switch ref {
            case .title:        return title
            case .series:       return "シリーズ\(variant)"
            case .author:       return "著者\(variant)"
            case .volume:       return String(format: "%02d", variant % 30 + 1)
            case .libraryType:  return template.libraryTypeName
            case .libraryName:  return "ライブラリ\(variant)"
            case .labelGroup(let n):
                let name = groupNames[n] ?? "グループ\(n)"
                return "\(name)値\(variant)"
            case .ignore:       return "無視\(variant)"
            }
        }
    }

    /// 1 プリセットぶんの正例。各フォーマットへ値を差し込む。
    static func positives(for template: LibraryTypeTemplate,
                          settings: LibrarySettingsSnapshot,
                          minimum: Int) throws -> [GoldenCase] {
        let withVolume = !settings.volumeFormats.isEmpty
        var out: [GoldenCase] = []
        var variant = 0
        while out.count < minimum {
            for (index, source) in template.filenameFormats.enumerated() {
                guard out.count < minimum else { break }
                let values = Values(template: template, variant: variant, withVolume: withVolume)
                let input = try synthesize(format: source, delimiters: settings.delimiters) { values($0) }
                variant += 1

                // 差し込んだ値がそのまま期待値になる。
                var fields: [String: String] = [:]
                let format = settings.filenameFormats[index]
                for ref in format.fieldOrder where !ref.discardsValue {
                    fields[FormatCompileError.label(ref)] = values(ref)
                }
                // 期待するシリーズ名と巻数は、@title から導かれる分だけ書く。
                var expectedSeries: String?
                var expectedVolume: GoldenCase.ExpectedVolume?
                if format.usedFields.contains(.title), !format.usedFields.contains(.series),
                   !format.usedFields.contains(.volume) {
                    let out = SeriesExtractor.extract(fromTitle: values.title,
                                                      patterns: settings.volumeFormats)
                    expectedSeries = out.seriesName
                    expectedVolume = GoldenRunner.ExpectedVolumeOf(out.volume)
                }

                out.append(GoldenCase(
                    kind: "positive",
                    id: "\(template.key).p\(out.count + 1)",
                    input: input + ".cbz",
                    context: .init(template: template.displayName, folderPath: nil),
                    expected: .init(matched: true, formatIndex: index, fields: fields,
                                    series: expectedSeries, volume: expectedVolume,
                                    labels: nil, libraryTypeMismatch: false)))
            }
        }
        return out
    }

    /// 1 プリセットぶんの負例。
    ///
    /// フォールバック（`@title` 単体）を持つプリセットでは「一致しない」入力を
    /// 20 件も作れないため、**「構造化されたフォーマットには当たらず末尾の
    /// フォールバックへ落ちる」**という主張に変える。
    static func negatives(for template: LibraryTypeTemplate,
                          settings: LibrarySettingsSnapshot,
                          minimum: Int) -> [GoldenCase] {
        let fallbackIndex = template.filenameFormats.firstIndex(of: "@title")
        let shapes: [String] = [
            "括弧のない名前", "著者名 タイトル", "[閉じ忘れ タイトル", "閉じだけ] タイトル",
            "[著者名]", "[] タイトル", "[   ] タイトル", "タイトル [著者名]",
            "{中括弧} タイトル", "〈山括弧〉 タイトル", "1234567890",
            "タイトルのみ", "－－－", "( ) タイトル", "]] [[",
            "タイトル(閉じない", "))))", "((((", "・・・", "　",
            "a", "ﾀｲﾄﾙ", "タイトル…続き", "@title", "＠タイトル",
        ]
        var out: [GoldenCase] = []
        for (i, shape) in shapes.enumerated() where out.count < minimum {
            let name = (shape as NSString).deletingPathExtension
            let actual = FilenameParser().parse(name, settings: settings, purpose: .libraryScan)
            let actualIndex = actual.flatMap { r in
                settings.filenameFormats.firstIndex { $0.id == r.matchedFormatID }
            }
            // フォールバックに落ちる、または一致しない、のどちらかであること。
            // 構造化フォーマットに当たってしまう形は負例として使えないので捨てる。
            if let actualIndex, actualIndex != fallbackIndex { continue }
            out.append(GoldenCase(
                kind: "negative",
                id: "\(template.key).n\(out.count + 1)",
                input: shape + ".cbz",
                context: .init(template: template.displayName, folderPath: nil),
                expected: .init(matched: actual != nil, formatIndex: actualIndex,
                                fields: nil, series: nil, volume: nil, labels: nil,
                                libraryTypeMismatch: actual.map { _ in false })))
            _ = i
        }
        return out
    }
}

@Suite("ゴールデンデータセットの生成（QOO_REGENERATE_GOLDEN=1 のときだけ走る）")
struct GoldenGeneratorTests {
    @Test("public データセットを作り直す [GT-03]")
    func regenerate() throws {
        guard ProcessInfo.processInfo.environment["QOO_REGENERATE_GOLDEN"] == "1" else { return }

        let volumeSets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let typeNames = Array(Set(presets.map(\.libraryTypeName))).sorted()
        let dir = GoldenRunner.directory("public")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        for preset in presets {
            let settings = try TemplateInstantiation.snapshot(
                from: preset, volumeSets: volumeSets, libraryID: LibraryID(rawValue: 1),
                allLibraryTypeNames: typeNames)
            let cases = try GoldenGenerator.positives(for: preset, settings: settings, minimum: 22)
                + GoldenGenerator.negatives(for: preset, settings: settings, minimum: 22)
            let dataset = GoldenDataset(datasetName: preset.key, visibility: "public", cases: cases)
            let name = preset.key.replacingOccurrences(of: "builtin.", with: "") + ".json"
            try encoder.encode(dataset).write(to: dir.appendingPathComponent(name), options: .atomic)
            let neg = cases.filter(\.isNegative).count
            FileHandle.standardError.write(Data(
                "[golden] \(name): 正例 \(cases.count - neg) / 負例 \(neg)\n".utf8))
        }
    }
}

// MARK: - private データセット（実ファイル名）

//
//  実コーパスからゴールデンケースを作る [16章 §16.2 の収集の導線][MT-27]。
//
//  public と違い、**期待値は現在の実装結果を初期値とする**——実データの正解は
//  人間にしか判定できないため、生成物を人が確認して確定させる [GT-03]。
//  出力先は `.gitignore` 済みで、実ファイル名はリポジトリに入らない [MT-28][B-14]。
//
enum PrivateGoldenGenerator {
    struct Corpus: Decodable {
        struct Entry: Decodable { let relativePath: String; let isDirectory: Bool }
        let libraryName: String
        let kind: String
        let entries: [Entry]
    }

    /// コーパスのライブラリ名 → 使うプリセット。
    static let presetByLibrary: [String: String] = [
        "成年コミック": "builtin.adult-comic-a",
        "同人誌": "builtin.doujinshi-a",
        "同人CG": "builtin.doujin-cg-b",     // サークル別サブフォルダがある
    ]

    static var corpusDir: URL { GoldenRunner.directory("private").appendingPathComponent("corpus") }

    static func load() -> [Corpus] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: corpusDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let d = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(Corpus.self, from: d)
        }
    }

    struct Report {
        var total = 0
        var matched = 0
        var byFormatIndex: [Int: Int] = [:]
        var unmatchedShapes: [String] = []       // 匿名化した形だけを残す
        var withVolume = 0
        var withSeries = 0
    }

    /// 実ファイル名を、構造だけ残して匿名化する。報告に実名を出さないため。
    static func shape(_ name: String) -> String {
        var out = ""
        var inWord = false
        for c in name {
            if c == "[" || c == "]" || c == "(" || c == ")" || c == "【" || c == "】" {
                out.append(c); inWord = false
            } else if Whitespace.isWhitespace(c) {
                out.append(" "); inWord = false
            } else if !inWord {
                out.append("x"); inWord = true
            }
        }
        return out
    }
}

@Suite("private ゴールデンデータセットの生成（QOO_REGENERATE_GOLDEN=1 かつコーパスがあるとき）")
struct PrivateGoldenGeneratorTests {
    @Test("実コーパスから private データセットを作る [MT-27][MT-28]")
    func regeneratePrivate() throws {
        guard ProcessInfo.processInfo.environment["QOO_REGENERATE_GOLDEN"] == "1" else { return }
        let corpora = PrivateGoldenGenerator.load()
        guard !corpora.isEmpty else {
            FileHandle.standardError.write(Data(
                "[golden/private] コーパスが無い。Scripts/extract-golden-corpus.swift を先に実行する\n".utf8))
            return
        }

        let volumeSets = try BuiltInTemplates.volumeSets()
        let presets = try BuiltInTemplates.libraryTypes()
        let typeNames = Array(Set(presets.map(\.libraryTypeName))).sorted()
        let dir = GoldenRunner.directory("private")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let parser = FilenameParser()

        for corpus in corpora {
            guard let presetKey = PrivateGoldenGenerator.presetByLibrary[corpus.libraryName],
                  let preset = presets.first(where: { $0.key == presetKey }) else { continue }
            let settings = try TemplateInstantiation.snapshot(
                from: preset, volumeSets: volumeSets, libraryID: LibraryID(rawValue: 1),
                allLibraryTypeNames: typeNames)

            var report = PrivateGoldenGenerator.Report()
            var cases: [GoldenCase] = []
            for entry in corpus.entries where !entry.isDirectory {
                let filename = (entry.relativePath as NSString).lastPathComponent
                guard !filename.hasPrefix(".") else { continue }
                let stem = (filename as NSString).deletingPathExtension
                report.total += 1

                let folderPath = (entry.relativePath as NSString).deletingLastPathComponent
                let resolved = FolderLabelResolver.resolve(
                    relativePath: entry.relativePath, nameWithoutExtension: stem, settings: settings)
                let result = parser.parse(stem, settings: settings, purpose: .libraryScan)

                var fields: [String: String] = [:]
                if let result {
                    report.matched += 1
                    if let index = settings.filenameFormats.firstIndex(where: {
                        $0.id == result.matchedFormatID
                    }) { report.byFormatIndex[index, default: 0] += 1 }
                    for (ref, value) in result.fields where !ref.discardsValue {
                        fields[FormatCompileError.label(ref)] = value.text
                    }
                } else {
                    report.unmatchedShapes.append(PrivateGoldenGenerator.shape(stem))
                }
                if resolved.volume.kind != .none { report.withVolume += 1 }
                if resolved.seriesName != nil { report.withSeries += 1 }

                cases.append(GoldenCase(
                    kind: result == nil ? "negative" : "positive",
                    id: "\(preset.key).real\(cases.count + 1)",
                    input: filename,
                    context: .init(template: preset.displayName,
                                   folderPath: folderPath.isEmpty ? nil : folderPath),
                    expected: .init(
                        matched: result != nil,
                        formatIndex: result.flatMap { r in
                            settings.filenameFormats.firstIndex { $0.id == r.matchedFormatID } },
                        fields: fields.isEmpty ? nil : fields,
                        series: resolved.seriesName,
                        volume: GoldenRunner.ExpectedVolumeOf(resolved.volume),
                        labels: nil,
                        libraryTypeMismatch: result?.libraryTypeMismatch)))
            }

            let dataset = GoldenDataset(datasetName: "real-\(corpus.libraryName)",
                                        visibility: "private", cases: cases)
            try encoder.encode(dataset)
                .write(to: dir.appendingPathComponent("real-\(corpus.libraryName).json"), options: .atomic)

            let rate = report.total > 0 ? 100.0 * Double(report.matched) / Double(report.total) : 0
            var lines = ["[golden/private] \(corpus.libraryName) → \(preset.displayName)",
                         "    \(report.matched)/\(report.total) 件が一致（\(String(format: "%.1f", rate))%）",
                         "    巻数あり \(report.withVolume) / シリーズあり \(report.withSeries)"]
            for (index, count) in report.byFormatIndex.sorted(by: { $0.value > $1.value }).prefix(5) {
                lines.append("    format[\(index)] \(preset.filenameFormats[index]) → \(count) 件")
            }
            let shapes = Dictionary(grouping: report.unmatchedShapes, by: { $0 })
                .mapValues(\.count).sorted { $0.value > $1.value }
            if !shapes.isEmpty {
                lines.append("    一致しなかった形（匿名化・上位 5）:")
                for (shape, count) in shapes.prefix(5) { lines.append("      \(count) 件  \(shape)") }
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
}
