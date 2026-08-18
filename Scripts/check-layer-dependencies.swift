#!/usr/bin/env swift
//
// CI static check B-11 [A-01][A-02]: 層の依存方向を機械的に守る。
//
//   ① `QooKit`（ドメイン層）は Foundation のみに依存する。
//      `SwiftData` / `GRDB` / `AppKit` / `SwiftUI` を import してはならない。
//   ② `GRDB` を import してよいのは `QooPersistence` だけ [A-02]。
//      永続化の実装詳細（SQL・接続・行の型）が上位層へ漏れると、
//      「Repository プロトコル越しに利用する」という抽象化が形骸化する。
//
// Usage: swift Scripts/check-layer-dependencies.swift

import Foundation

/// モジュール名 → そこで import してはならないモジュール
let rules: [(target: String, forbidden: [String], reason: String)] = [
    ("QooKit", ["SwiftData", "GRDB", "AppKit", "SwiftUI"], "A-01"),
    ("QooInfrastructure", ["GRDB", "SwiftData"], "A-02"),
    ("QooApplication", ["GRDB", "SwiftData"], "A-02"),
    ("qooLibraryApp", ["GRDB", "SwiftData"], "A-02"),
]

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

var violations: [String] = []
var checked = 0

for rule in rules {
    let root = repoRoot.appendingPathComponent("Sources").appendingPathComponent(rule.target)
    guard FileManager.default.fileExists(atPath: root.path) else { continue }
    checked += 1
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }

    for case let fileURL as URL in walker {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `@testable import` / `import struct X.Y` も拾う
            guard trimmed.contains("import ") else { continue }
            for module in rule.forbidden {
                let patterns = ["import \(module)", "import \(module).", "import \(module) "]
                let matches = patterns.contains { p in
                    trimmed == "import \(module)"
                        || trimmed.hasSuffix(" \(module)")
                        || trimmed.contains(p)
                }
                if matches, trimmed.hasPrefix("import") || trimmed.hasPrefix("@testable import") {
                    violations.append(
                        "\(fileURL.path):\(index + 1): \(rule.target) must not import \(module) [\(rule.reason)]")
                }
            }
        }
    }
}

guard checked > 0 else {
    print("==> No source targets found yet, nothing to check.")
    exit(0)
}

if violations.isEmpty {
    print("==> OK: layer dependencies are respected [A-01][A-02]")
    exit(0)
} else {
    print("!! Layer dependency violated:")
    for v in violations { print("  \(v)") }
    exit(1)
}
