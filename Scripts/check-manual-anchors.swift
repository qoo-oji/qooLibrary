#!/usr/bin/env swift
//
// CI static check [HP-07][HP-08]: アプリが開くマニュアルの節（`ManualSection` の
// `rawValue`）が、`MANUAL.md` の `<a id="…"></a>` として実在すること。
//
// Usage: swift Scripts/check-manual-anchors.swift
//
// ## なぜ機械的に検査するのか
// 「リンク先が実在しないうちはリンクを置かない」が決めごとだが、マニュアルの
// 見出しを直した・節を統合した、というときにアプリ側の識別子は黙って古くなる。
// ブラウザは存在しないアンカーでも文書の先頭を開くだけで**エラーにならない**
// ので、壊れたことに誰も気づけない。逆向き（マニュアルにあってアプリから
// 指されていない節）は問題ではないので検査しない。
//
// ## この検査はどんな実条件で落ちるか
// - `ManualSection` に case を足したが `MANUAL.md` に節を書いていない
// - `MANUAL.md` のアンカーを改名・削除したがアプリ側を追随させていない
// - どちらかのファイルが読めない／識別子を 1 つも抽出できない（空振りを
//   成功と読まないため [MT-30]）
//
// Note: 単純なテキストスキャンであり、Swift の完全な構文解析はしない
// （他の静的検査と同じ方針）。

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = repoRoot.appendingPathComponent("Sources/qooLibraryApp/Help/ManualLink.swift")
let manualURL = repoRoot.appendingPathComponent("MANUAL.md")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
    fail("\(sourceURL.path) を読めませんでした")
}
guard let manual = try? String(contentsOf: manualURL, encoding: .utf8) else {
    fail("\(manualURL.path) を読めませんでした")
}

/// `enum ManualSection` の本体から `case x = "anchor"` / `case x` を拾う。
/// 明示的な rawValue が無ければ case 名がそのままアンカー。
func referencedAnchors(in source: String) -> [String] {
    var anchors: [String] = []
    var inEnum = false
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("enum ManualSection") { inEnum = true; continue }
        guard inEnum else { continue }
        if line == "}" { break }
        guard line.hasPrefix("case ") else { continue }
        let body = line.dropFirst("case ".count)
        if let eq = body.firstIndex(of: "=") {
            let raw = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            anchors.append(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        } else {
            anchors.append(String(body).trimmingCharacters(in: .whitespaces))
        }
    }
    return anchors
}

func definedAnchors(in manual: String) -> Set<String> {
    let pattern = try! NSRegularExpression(pattern: #"<a id="([A-Za-z0-9_-]+)"></a>"#)
    let range = NSRange(manual.startIndex..., in: manual)
    return Set(pattern.matches(in: manual, range: range).compactMap {
        Range($0.range(at: 1), in: manual).map { String(manual[$0]) }
    })
}

let referenced = referencedAnchors(in: source)
let defined = definedAnchors(in: manual)

// 空振りを成功と読まない [MT-30]。
guard !referenced.isEmpty else { fail("ManualLink.swift から ManualSection の case を 1 つも読めませんでした") }
guard !defined.isEmpty else { fail("MANUAL.md から <a id=\"…\"></a> を 1 つも読めませんでした") }

let missing = referenced.filter { !defined.contains($0) }
if !missing.isEmpty {
    for anchor in missing {
        FileHandle.standardError.write(
            Data("error: MANUAL.md に <a id=\"\(anchor)\"></a> がありません（ManualSection が参照）\n".utf8))
    }
    exit(1)
}
print("✓ check-manual-anchors: ManualSection \(referenced.count) 件すべてが MANUAL.md に実在する")
