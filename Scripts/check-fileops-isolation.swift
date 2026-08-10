#!/usr/bin/env swift
//
// CI static check B-10 [FO-02]: `FileManager` の変更系 API
// (moveItem/copyItem/removeItem/createDirectory/trashItem/createFile/
// linkItem/replaceItem) は `QooInfrastructure/FileOps/` 配下からしか
// 呼んではならない。これに違反する呼び出しが `Sources/` の他の場所に
// あればビルドを失敗させる。
//
// Usage: swift Scripts/check-fileops-isolation.swift
//
// Note: 単純なテキストスキャンであり、Swift の完全な構文解析はしない
// （B-10 の意図であるレビュー漏れの機械的検出には十分）。
//
// `FileOperationService` 自身が `rename`/`createDirectory` 等、FileManager と
// 同名のメソッドを公開している（spec 上意図した命名）ため、行に "FileManager"
// という文字列が現れている場合のみを違反候補とする。`fileOps.createDirectory(...)`
// のような正当な呼び出しを誤検知しないようにするための最小限の対策。

import Foundation

let forbiddenMethods = [
    "moveItem", "copyItem", "removeItem", "createDirectory",
    "trashItem", "createFile", "linkItem", "replaceItem",
]

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourcesRoot = repoRoot.appendingPathComponent("Sources")
let allowedPrefix = sourcesRoot
    .appendingPathComponent("QooInfrastructure")
    .appendingPathComponent("FileOps")
    .path

var violations: [String] = []

func scan(_ url: URL) {
    guard let fm = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey])
    else { return }

    for case let fileURL as URL in fm {
        guard fileURL.pathExtension == "swift" else { continue }
        if fileURL.path.hasPrefix(allowedPrefix) { continue }

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            guard line.contains("FileManager") else { continue }
            for method in forbiddenMethods {
                if line.contains(".\(method)(") {
                    violations.append("\(fileURL.path):\(index + 1): forbidden FileManager API `\(method)` outside FileOps — \(trimmed)")
                }
            }
        }
    }
}

guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
    print("==> Sources/ not found yet, nothing to check.")
    exit(0)
}

scan(sourcesRoot)

if violations.isEmpty {
    print("==> OK: no FileManager mutating API calls found outside QooInfrastructure/FileOps [FO-02]")
    exit(0)
} else {
    print("!! FileOps isolation violated [FO-01][FO-02]:")
    for v in violations { print("  \(v)") }
    exit(1)
}
