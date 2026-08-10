#!/usr/bin/env swift
//
// CI static check B-13 [MG-23]: `@Model` の非再生成属性（`@Regenerable`
// 未付与のプロパティ）はすべて JSON エクスポート DTO に含まれていなければ
// ならない。再生成不可能なデータ（手動ラベル・評価・手動編集タイトル等、
// 07章 §7.2「再生成可能性のマーキング」参照）が JSON 往復で失われることを
// 防ぐための検査。
//
// 現状（フェーズ 0）では `@Model` 型も JSON DTO も存在しないため、本スクリプト
// は「対象なし」として成功終了する。QooPersistence に `@Model` 型が追加され、
// JSON 入出力（07章 §7.5）が実装されたら、以下を検証するロジックに拡張する:
//   1. `@Model final class` 内の各 `public var` プロパティを列挙
//   2. `@Regenerable` が付与されていないものを「要保全」としてマークする
//   3. 対応する `<ModelName>DTO`（または JSON エンコード処理）が
//      「要保全」プロパティをすべて含んでいるかを確認する
//   4. 含まれていなければ失敗させる
//
// Usage: swift Scripts/check-json-completeness.swift

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let persistenceRoot = repoRoot.appendingPathComponent("Sources").appendingPathComponent("QooPersistence")

func containsModelDeclaration(_ root: URL) -> Bool {
    guard let fm = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return false }
    for case let fileURL as URL in fm {
        guard fileURL.pathExtension == "swift" else { continue }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        for line in contents.components(separatedBy: .newlines) {
            // Only match an actual declaration (`@Model final class ...`),
            // not the substring appearing inside a doc comment.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("@Model") {
                return true
            }
        }
    }
    return false
}

guard FileManager.default.fileExists(atPath: persistenceRoot.path),
      containsModelDeclaration(persistenceRoot)
else {
    print("==> OK: no @Model types yet, nothing to check [MG-23] (placeholder — see file header for the intended full check)")
    exit(0)
}

print("!! @Model types were found but check-json-completeness.swift has not been implemented yet.")
print("   Implement the JSON DTO completeness check described in this file's header before merging JSON import/export work [MG-23][JS-02].")
exit(1)
