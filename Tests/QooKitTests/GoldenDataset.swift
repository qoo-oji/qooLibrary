//
//  ゴールデンテストの器 [16章 §16.2][MT-20〜MT-28][GT-01〜GT-07]。
//
//  **ファイル名パーサの正しさを担保する主要手段。**パーサに変更を加えたら全件を
//  実行し、差分が出たら「期待結果を更新する」か「実装を直す」かを明示的に判断する
//  [GT-03][MT-24]。実運用で誤判定が見つかったら、**そのファイル名を必ず
//  データセットへ追加してから修正する** [GT-04][MT-25]。
//
//  実在の作品名・著者名を含むサンプルは `private/` に置き `.gitignore` する。
//  CI は `public/` のみ実行する [GT-07][MT-28][B-14]。
//
//  DTO はいまテストターゲットに置いている。2-14（未解決ファイルの整理ウインドウ）で
//  GT-05（UI からのサンプル書き出し）を実装するときに製品コードへ移すこと。
//
import Foundation
import Testing
@testable import QooKit

// MARK: - データセットの形

struct GoldenDataset: Codable {
    let datasetName: String
    let visibility: String            // public | private [MT-28]
    let cases: [GoldenCase]
}

struct GoldenCase: Codable {
    struct Context: Codable {
        /// プリセットの表示名（`一般コミック(B)` 等）または `key`。
        let template: String
        /// ライブラリ根からの相対パス（ディレクトリ部分の検証に使う）[AL-20]。
        let folderPath: String?
    }

    struct ExpectedVolume: Codable, Equatable {
        let kind: String              // numeric | ordinal | none
        let number: Double?
        let raw: String?
    }

    struct Expected: Codable {
        let matched: Bool
        /// テンプレートの `filenameFormats` における添字 [FF-03]。
        let formatIndex: Int?
        /// 予約語 → 抽出値（`@title` `@circle` 等）。
        let fields: [String: String]?
        let series: String?
        let volume: ExpectedVolume?
        /// ラベルグループ名 → 付与されるラベル。
        let labels: [String: [String]]?
        /// `@booktype` の不一致が立つか [RW-01]。
        let libraryTypeMismatch: Bool?
    }

    /// `positive` | `negative`。
    ///
    /// **`negative` は「どのフォーマットにも一致しない」とは限らない** [設計判断]。
    /// 一般コミック(B) と成年コミック(B) は `@title` 単体をフォールバックとして
    /// 持つため、空白だけの入力を除けばほぼ何でも一致する。それらのプリセットで
    /// 意味のある負例は「**構造化されたフォーマットには当たらず、フォールバックへ
    /// 落ちる**」という主張であり、`matched: true` + `formatIndex: <末尾>` で表す。
    /// GT-02 の「負例 20 件」はこの意味で数える [MT-23]。
    let kind: String?
    let id: String
    let input: String
    let context: Context
    let expected: Expected

    var isNegative: Bool { kind == "negative" || !expected.matched }
}

// MARK: - 実行

enum GoldenRunner {
    /// `visibility` ごとのデータセット置き場。
    static func directory(_ visibility: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // QooKitTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("GoldenDataset/\(visibility)")
    }

    static func load(_ visibility: String) throws -> [GoldenDataset] {
        let dir = directory(visibility)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return try files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(GoldenDataset.self, from: Data(contentsOf: $0)) }
    }

    /// テンプレート名 → 設定スナップショット。テンプレートごとに 1 回だけ作る。
    static let snapshots: [String: (LibrarySettingsSnapshot, LibraryTypeTemplate)] = {
        guard let sets = try? BuiltInTemplates.volumeSets(),
              let presets = try? BuiltInTemplates.libraryTypes() else { return [:] }
        let typeNames = Array(Set(presets.map(\.libraryTypeName))).sorted()
        var out: [String: (LibrarySettingsSnapshot, LibraryTypeTemplate)] = [:]
        for preset in presets {
            guard let s = try? TemplateInstantiation.snapshot(
                from: preset, volumeSets: sets, libraryID: LibraryID(rawValue: 1),
                allLibraryTypeNames: typeNames) else { continue }
            out[preset.displayName] = (s, preset)
            out[preset.key] = (s, preset)
        }
        return out
    }()

    struct Failure: CustomStringConvertible {
        let caseID: String
        let reason: String
        var description: String { "[\(caseID)] \(reason)" }
    }

    /// 1 件を検証し、食い違いを返す（空なら合格）。
    static func verify(_ testCase: GoldenCase) -> [Failure] {
        guard let (settings, template) = snapshots[testCase.context.template] else {
            return [Failure(caseID: testCase.id,
                            reason: "テンプレートが見つからない: \(testCase.context.template)")]
        }
        var failures: [Failure] = []
        func fail(_ reason: String) { failures.append(Failure(caseID: testCase.id, reason: reason)) }

        let name = (testCase.input as NSString).deletingPathExtension
        let result = FilenameParser().parse(name, settings: settings, purpose: .libraryScan)

        guard testCase.expected.matched else {
            if result != nil { fail("一致しないはずが一致した: \(testCase.input)") }
            return failures
        }
        guard let result else {
            return [Failure(caseID: testCase.id, reason: "一致するはずが一致しない: \(testCase.input)")]
        }

        if let index = testCase.expected.formatIndex {
            let actual = settings.filenameFormats.firstIndex { $0.id == result.matchedFormatID }
            if actual != index { fail("formatIndex 期待 \(index) / 実際 \(actual.map(String.init) ?? "nil")") }
        }

        if let fields = testCase.expected.fields {
            for (key, expected) in fields {
                guard let ref = fieldRef(key) else { fail("未知の予約語: \(key)"); continue }
                let actual = result.fields[ref]?.text
                if actual != expected { fail("\(key) 期待 \(expected.debugDescription) / 実際 \(actual.debugDescription)") }
            }
        }

        let resolved = FolderLabelResolver.resolve(
            relativePath: (testCase.context.folderPath.map { $0 + "/" } ?? "") + testCase.input,
            nameWithoutExtension: name,
            settings: settings)

        if let expectedSeries = testCase.expected.series, resolved.seriesName != expectedSeries {
            fail("series 期待 \(expectedSeries.debugDescription) / 実際 \(resolved.seriesName.debugDescription)")
        }
        if let v = testCase.expected.volume {
            let actual = ExpectedVolumeOf(resolved.volume)
            if actual != v { fail("volume 期待 \(v) / 実際 \(actual)") }
        }
        if let expectedMismatch = testCase.expected.libraryTypeMismatch,
           result.libraryTypeMismatch != expectedMismatch {
            fail("libraryTypeMismatch 期待 \(expectedMismatch) / 実際 \(result.libraryTypeMismatch)")
        }
        if let expectedLabels = testCase.expected.labels {
            let namesByIndex = Dictionary(uniqueKeysWithValues:
                template.labelGroups.map { ($0.index, $0.name) })
            var actual: [String: [String]] = [:]
            for (index, values) in resolved.labels {
                guard let groupName = namesByIndex[index] else { continue }
                actual[groupName] = values
            }
            for (group, values) in expectedLabels {
                if actual[group] != values {
                    fail("labels[\(group)] 期待 \(values) / 実際 \(actual[group].map(String.init(describing:)) ?? "nil")")
                }
            }
        }
        return failures
    }

    static func ExpectedVolumeOf(_ v: VolumeValue) -> GoldenCase.ExpectedVolume {
        GoldenCase.ExpectedVolume(kind: v.kind.rawValue, number: v.number, raw: v.raw)
    }

    /// 期待値の鍵（予約語の綴り）→ フィールド。
    ///
    /// **可変長の鍵はもう無い。** `@labelgroupN` は v3 ステージ 5 で撤去した。
    static func fieldRef(_ key: String) -> FieldRef? {
        ReservedWordTable.entries.first { $0.word == key }?.field
    }
}

// MARK: - テスト

@Suite("ゴールデンテスト [MT-20〜MT-28]")
struct GoldenDatasetTests {

    @Test("public データセットが全件一致する [GT-03][B-14]")
    func publicDatasets() throws {
        let datasets = try GoldenRunner.load("public")
        #expect(!datasets.isEmpty, "public のデータセットが 1 つも無い")
        var total = 0
        var failures: [GoldenRunner.Failure] = []
        for dataset in datasets {
            #expect(dataset.visibility == "public", "\(dataset.datasetName) の visibility が public でない")
            for c in dataset.cases {
                total += 1
                failures += GoldenRunner.verify(c)
            }
        }
        if !failures.isEmpty {
            Issue.record("""
                \(failures.count) 件が食い違った（全 \(total) 件）:
                \(failures.prefix(30).map(\.description).joined(separator: "\n"))
                """)
        }
        FileHandle.standardError.write(Data(
            "[golden] public: \(datasets.count) データセット / \(total) 件\n".utf8))
    }

    /// 実在の作品名を含むデータセット。**ローカルにあるときだけ実行する** [GT-07]。
    @Test("private データセットが全件一致する（ローカルのみ）")
    func privateDatasets() throws {
        let datasets = try GoldenRunner.load("private")
        guard !datasets.isEmpty else {
            FileHandle.standardError.write(Data(
                "[golden] private: 未配置のため飛ばす（Scripts/generate-golden-dataset.swift で作る）\n".utf8))
            return
        }
        var total = 0
        var failures: [GoldenRunner.Failure] = []
        for dataset in datasets {
            for c in dataset.cases {
                total += 1
                failures += GoldenRunner.verify(c)
            }
        }
        if !failures.isEmpty {
            Issue.record("""
                \(failures.count) 件が食い違った（全 \(total) 件）:
                \(failures.prefix(30).map(\.description).joined(separator: "\n"))
                """)
        }
        FileHandle.standardError.write(Data(
            "[golden] private: \(datasets.count) データセット / \(total) 件\n".utf8))
    }

    /// GT-02: プリセット 8 種それぞれについて正例・負例を最低 20 件ずつ。
    @Test("public データセットが GT-02 の件数要件を満たす [MT-23]")
    func coverageRequirement() throws {
        let datasets = try GoldenRunner.load("public")
        var positive: [String: Int] = [:]
        var negative: [String: Int] = [:]
        for dataset in datasets {
            for c in dataset.cases {
                let template = GoldenRunner.snapshots[c.context.template].map { _ in c.context.template }
                    ?? c.context.template
                if c.isNegative { negative[template, default: 0] += 1 }
                else { positive[template, default: 0] += 1 }
            }
        }
        let presets = try BuiltInTemplates.libraryTypes()
        var shortfall: [String] = []
        for preset in presets {
            let p = positive[preset.displayName] ?? 0
            let n = negative[preset.displayName] ?? 0
            if p < 20 || n < 20 { shortfall.append("\(preset.displayName): 正例 \(p) / 負例 \(n)") }
        }
        if !shortfall.isEmpty {
            Issue.record("""
                GT-02（プリセット 8 種 × 正例・負例 各 20 件以上）を満たしていない:
                \(shortfall.joined(separator: "\n"))
                """)
        }
    }
}
