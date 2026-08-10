#!/usr/bin/env swift
//
// CI static check B-11 [A-01]: `QooKit`（ドメイン層）は Foundation のみに
// 依存する。`SwiftData` / `AppKit` / `SwiftUI` を import していたら
// ビルドを失敗させる。
//
// Usage: swift Scripts/check-layer-dependencies.swift

import Foundation

let forbiddenImports = ["SwiftData", "AppKit", "SwiftUI"]

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let qooKitRoot = repoRoot.appendingPathComponent("Sources").appendingPathComponent("QooKit")

var violations: [String] = []

func scan(_ url: URL) {
    guard let fm = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey])
    else { return }

    for case let fileURL as URL in fm {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for module in forbiddenImports {
                if trimmed == "import \(module)" || trimmed.hasPrefix("import \(module) ") {
                    violations.append("\(fileURL.path):\(index + 1): QooKit must not import \(module) [A-01]")
                }
            }
        }
    }
}

guard FileManager.default.fileExists(atPath: qooKitRoot.path) else {
    print("==> Sources/QooKit not found yet, nothing to check.")
    exit(0)
}

scan(qooKitRoot)

if violations.isEmpty {
    print("==> OK: QooKit has no SwiftData/AppKit/SwiftUI imports [A-01]")
    exit(0)
} else {
    print("!! Layer dependency violated [A-01]:")
    for v in violations { print("  \(v)") }
    exit(1)
}
