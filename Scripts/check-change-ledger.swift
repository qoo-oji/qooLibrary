#!/usr/bin/env swift
//
// CI static check [FO-11][FO-12]: `FileOperationService` の各操作は、
// 変更を通知する（`defer { announce(...) }`）より**前**に、期待変更台帳へ
// 登録しなければならない（`expect(...)`）。
//
// `announce` は `defer` で走る＝操作の**後**なので、それだけでは台帳が
// 間に合わない——長い操作の途中で FSEvents が届くと、自分の変更を外部変更と
// 誤認する。この検査は「新しい操作を足したときに `expect` を忘れる」ことを
// 機械的に止める。FO-02 の隔離検査と同じ考え方（書き忘れを構造的に防ぐ）。
//
// Usage: swift Scripts/check-change-ledger.swift

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let target = repoRoot.appendingPathComponent(
    "Sources/QooInfrastructure/FileOps/FileOperationService.swift")

guard let contents = try? String(contentsOf: target, encoding: .utf8) else {
    print("==> \(target.lastPathComponent) が無い。何も検査しない。")
    exit(0)
}

let lines = contents.components(separatedBy: .newlines)
/// `defer { announce` の直前 6 行以内に `expect(` があること。
let lookBehind = 6
var violations: [String] = []
var checked = 0

for (index, line) in lines.enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("defer { announce(") else { continue }
    checked += 1
    let start = max(0, index - lookBehind)
    let window = lines[start..<index]
    let hasExpect = window.contains {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("expect(") && !t.hasPrefix("//")
    }
    if !hasExpect {
        violations.append("\(target.path):\(index + 1): `defer { announce(...) }` の前に `expect(...)` が無い [FO-11] — \(trimmed)")
    }
}

guard checked > 0 else {
    print("!! `defer { announce(...) }` が 1 件も見つからない。検査が空振りしている可能性がある。")
    exit(1)
}

if violations.isEmpty {
    print("==> OK: \(checked) 件の変更通知すべてに事前の台帳登録がある [FO-11]")
    exit(0)
} else {
    print("!! 期待変更台帳への事前登録が漏れている [FO-11]:")
    for v in violations { print("  \(v)") }
    exit(1)
}
