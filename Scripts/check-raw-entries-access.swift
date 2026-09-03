#!/usr/bin/env swift
//
// CI static check [§19.13 #6][VM-01][VM-02]: 中央ペインの一覧の源は 2 つある
// （`entries` ＝ 実体の直下 / `libraryContent.rows` ＝ DB）。**画面に出ている
// 一覧を指すのは `displayedEntries` だけ**なので、生の `entries` を読む箇所は
// 印を付けて明示する。
//
// Usage: swift Scripts/check-raw-entries-access.swift
//
// ## なぜ機械的に縛るのか
// 表示モードの要件 [VM-01][VM-03] 上、源は 2 つ要る——フォルダ表示モードでは
// DB に載っていないもの（対象拡張子以外）も従来どおり見えなければならず、
// ライブラリ表示モードは配下からフラットに集めた DB の行を描く。
//
// **ライブラリ表示モードでは `entries` に無い行が画面に並ぶ**ので、`entries`
// を読む箇所は「フォルダ表示モードにしか効かない」ことになる。しかも症状は
// 例外でもエラーでもなく**「何も起きない」**——2-9 では `displayedEntries` への
// 移し忘れが 5 件あり、「開く」が無反応・⌘R が黙って効かない・FSEvents の
// たびに選択が消える、という形で出た（すべて code-review が拾った）。
//
// 印を要求すれば、次に `entries` を読む人が**そのとき一度だけ**「これは
// フォルダ表示モード限定でよいか」を考えることになる。
//
// ## 印の書き方
// 行そのものか直前の行に `[raw-entries]` を含むコメントを置く。
//
//     // [raw-entries] 実体の直下だけを数える。
//     let currentURLs = Set(entries.map(\.url))
//
// Note: 単純なテキストスキャンであり、Swift の完全な構文解析はしない
// （他の静的検査と同じ方針）。

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let checkedFile = repoRoot
    .appendingPathComponent("Sources/qooLibraryApp/MainWindow/FolderContentView.swift")

let marker = "[raw-entries]"

/// `entries` を**読んで**いるか。
///
/// 対象外にするもの:
/// - 宣言（`var entries: …` / `let entries: …`）
/// - 代入（`entries = …`）
/// - 引数ラベル・プロパティ名（`Step(entries: batch)` / `entries: displayedEntries`）
/// - 別の型のメンバ（`step.entries`）と別名（`displayedEntries`）
func readsRawEntries(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("//") { return false }

    var index = line.startIndex
    while let range = line.range(of: "entries", range: index..<line.endIndex) {
        index = range.upperBound
        let before = line[line.startIndex..<range.lowerBound]
        let after = line[range.upperBound...]

        // 語の境界。直前が識別子の文字・`.` なら別のもの。
        if let ch = before.last, ch.isLetter || ch.isNumber || ch == "_" || ch == "." { continue }
        if let ch = after.first, ch.isLetter || ch.isNumber || ch == "_" { continue }

        // 宣言。
        let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
        if beforeTrimmed.hasSuffix("var") || beforeTrimmed.hasSuffix("let") { continue }
        // 引数ラベル・プロパティ名。
        if after.hasPrefix(":") { continue }
        // 代入（`==` は比較なので読み取り）。
        let afterTrimmed = after.trimmingCharacters(in: .whitespaces)
        if afterTrimmed.hasPrefix("=") && !afterTrimmed.hasPrefix("==") { continue }

        return true
    }
    return false
}

guard let contents = try? String(contentsOf: checkedFile, encoding: .utf8) else {
    print("==> \(checkedFile.lastPathComponent) not found yet, nothing to check.")
    exit(0)
}

let lines = contents.components(separatedBy: .newlines)
var violations: [String] = []

for (index, line) in lines.enumerated() {
    guard readsRawEntries(line) else { continue }
    let previous = index > 0 ? lines[index - 1] : ""
    if line.contains(marker) || previous.contains(marker) { continue }
    let relative = checkedFile.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    violations.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
}

if violations.isEmpty {
    print("==> OK: 生の `entries` を読む箇所はすべて印付き [§19.13 #6]")
    exit(0)
} else {
    print("!! 生の `entries` を読んでいる（画面の一覧は `displayedEntries`）[§19.13 #6]:")
    for v in violations { print("  \(v)") }
    print("")
    print("   ライブラリ表示モードでは `entries` に無い行が画面に並ぶ [VM-10]。")
    print("   画面に出ているものを指したいなら `displayedEntries` を使うこと。")
    print("   フォルダ表示モード限定でよいと確かめたなら、その行か直前の行に")
    print("   `\(marker)` を含むコメントで理由を書く。")
    exit(1)
}
