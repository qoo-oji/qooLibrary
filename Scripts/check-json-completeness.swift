#!/usr/bin/env swift
//
// CI 静的検査 B-13 [MG-23][BK-05]: 再生成不可能なデータが JSON へ漏れなく
// 出ることを守る仕掛けが、外れていないことを確かめる。
//
// ## この検査は何を見て、何を見ないか
// **網羅性そのものは静的には確かめられない。** 「列」は実行時の SQLite の
// スキーマからしか読めず、「JSON のキー」は実際に符号化しないと分からない
// ためで、それを実際に突き合わせるのは
// `Tests/QooPersistenceTests/BackupTests.swift` の
// `exportCoversEveryNonRegenerableColumn` である（実 DB の列 × 実 JSON のキー）。
//
// ここで守るのは、**その仕掛けが成立するための前提** 2 つ:
//
//   1. `RegenerabilityDeclaring` に適合させた型が、`RegenerabilityRegistry
//      .declaringTypes` に登録されている。登録を忘れた型は検証の対象外に
//      なるので、**テストは通るのに漏れる**——最も危ない壊れ方。
//   2. 網羅性を検証するテストが実在する。
//
// ## この検査はどんな実条件で落ちるか [CLAUDE.md の作法]
//   - 新しいレコード型に `RegenerabilityDeclaring` を足し、`declaringTypes`
//     への追加を忘れたとき（1）
//   - 網羅性テストを消した・改名したとき（2）
//
// Usage: swift Scripts/check-json-completeness.swift

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

func read(_ relativePath: String) -> String? {
    try? String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
}

var failures: [String] = []

// --- 1. 適合させた型がすべて登録されているか ---------------------------------

let regenerabilityPath = "Sources/QooPersistence/Schema/Regenerability.swift"
guard let regenerability = read(regenerabilityPath) else {
    FileHandle.standardError.write(Data("==> FAIL: \(regenerabilityPath) が読めない\n".utf8))
    exit(1)
}

// `extension <型名>: RegenerabilityDeclaring {`
var conformingTypes: [String] = []
for line in regenerability.components(separatedBy: .newlines) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("extension "), trimmed.contains(": RegenerabilityDeclaring") else {
        continue
    }
    let afterKeyword = trimmed.dropFirst("extension ".count)
    let name = afterKeyword.prefix { $0 != ":" && !$0.isWhitespace }
    if !name.isEmpty { conformingTypes.append(String(name)) }
}

guard !conformingTypes.isEmpty else {
    FileHandle.standardError.write(Data(
        "==> FAIL: RegenerabilityDeclaring に適合する型が 1 つも見つからない（検査が空振りしている）\n".utf8))
    exit(1)
}

// `declaringTypes` の配列に並ぶ `X.self` を集める。
var registered: Set<String> = []
if let start = regenerability.range(of: "declaringTypes: [any RegenerabilityDeclaring.Type] = [") {
    let rest = regenerability[start.upperBound...]
    if let end = rest.range(of: "]") {
        for entry in rest[..<end.lowerBound].components(separatedBy: ",") {
            let token = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.hasSuffix(".self") else { continue }
            registered.insert(String(token.dropLast(".self".count)))
        }
    }
}

for type in conformingTypes where !registered.contains(type) {
    failures.append("""
        \(type) が RegenerabilityRegistry.declaringTypes に登録されていない [MG-23]。
            登録しないと、この型の列は JSON 網羅性の検証対象から外れる
            ——テストは通るのに、再生成不可能なデータが黙って漏れる。
        """)
}

// --- 2. 網羅性を検証するテストが実在するか -----------------------------------

let testPath = "Tests/QooPersistenceTests/BackupTests.swift"
if let tests = read(testPath) {
    if !tests.contains("func exportCoversEveryNonRegenerableColumn") {
        failures.append("""
            \(testPath) に exportCoversEveryNonRegenerableColumn が無い [MG-23][BK-05]。
                実 DB の列と実 JSON のキーを突き合わせるのはこのテストだけで、
                これが消えると網羅性を誰も確かめていない状態になる。
            """)
    }
    if !tests.contains("RegenerabilityRegistry.declaringTypes") {
        failures.append("""
            \(testPath) の網羅性テストが RegenerabilityRegistry を見ていない。
                宣言から導かずに列を手書きすると、列を足したときに漏れる。
            """)
    }
} else {
    failures.append("\(testPath) が無い [MG-23]。JSON 網羅性の検証が消えている。")
}

// --- 結果 -------------------------------------------------------------------

if failures.isEmpty {
    print("==> OK: 再生成可能性の宣言 \(conformingTypes.count) 型がすべて登録され、"
          + "JSON 網羅性の検証が存在する [MG-23][B-13]")
    exit(0)
}
FileHandle.standardError.write(Data(
    ("==> FAIL: JSON 網羅性の仕掛けが成立していない [MG-23][B-13]\n"
     + failures.map { "  - " + $0 }.joined(separator: "\n") + "\n").utf8))
exit(1)
