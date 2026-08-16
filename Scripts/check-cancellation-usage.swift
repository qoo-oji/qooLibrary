#!/usr/bin/env swift
//
// CI static check [NV6-01][NV6-03]: `QooInfrastructure/FileOps/` 配下と
// `QooKit/Model/PauseToken.swift` では `Task.isCancelled` を使ってはならない。
// 代わりに `Cancellation.isRequested` を使う。
//
// Usage: swift Scripts/check-cancellation-usage.swift
//
// ## なぜ機械的に禁じるのか
// この層のブロッキング処理は `FileIO.perform` が借りたディスパッチスレッドの
// 上で走る。**そこには Task の文脈が無いので `Task.isCancelled` は常に
// `false` を返す**——コンパイルは通り、警告も出ず、取り消しの判定だけが
// 静かに死ぬ。実測では `PauseToken.waitWhilePaused` がこれで永久にハングした
// （一時停止した処理を二度と止められない）。
//
// `Cancellation.isRequested` は範囲の中なら旗を、外なら `Task.isCancelled` を
// 見るので、**どちらの世界から呼ばれても正しい**。したがって「この層では
// 常にそちらを使う」で困る場面が無く、機械的に禁じられる。
//
// Note: 単純なテキストスキャンであり、Swift の完全な構文解析はしない
// （他の静的検査と同じ方針。レビュー漏れの機械的検出には十分）。

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourcesRoot = repoRoot.appendingPathComponent("Sources")

/// 検査対象。`FileIO.perform` の中で走り得るコードが置かれている場所。
let checkedRoots = [
    sourcesRoot.appendingPathComponent("QooInfrastructure").appendingPathComponent("FileOps"),
    sourcesRoot.appendingPathComponent("QooKit").appendingPathComponent("Model")
        .appendingPathComponent("PauseToken.swift"),
]

var violations: [String] = []

func check(_ fileURL: URL) {
    guard fileURL.pathExtension == "swift" else { return }
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
    for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // コメントは対象外 — 「なぜ使ってはいけないか」を説明する記述が
        // 各所にあり、それを違反として数えては本末転倒になる。
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
        guard line.contains("Task.isCancelled") else { continue }
        let relative = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
        violations.append(
            "\(relative):\(index + 1): use `Cancellation.isRequested` instead of `Task.isCancelled` — \(trimmed)"
        )
    }
}

func scan(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
    guard isDirectory.boolValue else { return check(url) }
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey])
    else { return }
    for case let fileURL as URL in enumerator { check(fileURL) }
}

guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
    print("==> Sources/ not found yet, nothing to check.")
    exit(0)
}

for root in checkedRoots { scan(root) }

if violations.isEmpty {
    print("==> OK: no `Task.isCancelled` in blocking file-I/O code [NV6-01][NV6-03]")
    exit(0)
} else {
    print("!! `Task.isCancelled` does not work on the borrowed threads used by FileIO.perform [NV6-01]:")
    for v in violations { print("  \(v)") }
    print("")
    print("   `Task.isCancelled` returns false when there is no current Task, so the check")
    print("   silently never fires. Use `Cancellation.isRequested` (QooKit/Model/Cancellation.swift),")
    print("   which falls back to `Task.isCancelled` outside of a FileIO scope.")
    exit(1)
}
