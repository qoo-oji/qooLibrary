#!/usr/bin/env swift
import Foundation

// コードが参照している文字列カタログの鍵が、実際に定義されているかを検査する。
//
// **なぜ要るのか**［エラー文言の棚卸しで発見］: `error.moveFailed` が
// コード中で使われているのにカタログに無く、移動が失敗したときのダイアログの
// 題が**生の鍵のまま**（`error.moveFailed`）表示される状態になっていた。
// `String(localized:)` は鍵が無いと鍵自身を返すため、コンパイルも実行も
// 通ってしまい、実際にその操作を失敗させないと気づけない。
//
// 逆方向（カタログにあるがコードから使われていない）は**検査しない** —
// 動的に組み立てる鍵や、将来のために置いた文言を誤検出するため。
// 害の非対称（出ない文言 vs 生の鍵が出る）に合わせて、片方向だけ見る。

let sources = "Sources"
let catalogPath = "Resources/Localizable.xcstrings"

guard let data = FileManager.default.contents(atPath: catalogPath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let strings = json["strings"] as? [String: Any]
else {
    print("==> FAIL: \(catalogPath) を読めない")
    exit(1)
}
let defined = Set(strings.keys)

// 鍵の「先頭の部品」（`error`, `folder`, `action` …）を定義済みの鍵から学ぶ。
// これを使って「本アプリの鍵らしい文字列」だけを検査対象にする。
// bundle ID（`com.apple.Terminal`）や UTI（`public.folder`）のような、
// 見た目の似た別物を巻き込まないため。
let knownPrefixes = Set(defined.compactMap { $0.split(separator: ".").first.map(String.init) })

let keyPattern = try! NSRegularExpression(pattern: #""([a-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)""#)
var missing: [(key: String, file: String, line: Int)] = []

let enumerator = FileManager.default.enumerator(atPath: sources)
while let relative = enumerator?.nextObject() as? String {
    guard relative.hasSuffix(".swift") else { continue }
    let path = "\(sources)/\(relative)"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    // **SF Symbol 名だけを返すメンバの中は丸ごと除く。** `systemImage:` 引数の
    // 直後という形（下の `isSymbolArgument`）では、`var systemImage: String` の
    // 中で `switch` して名前を返す書き方（`StandardLocation` がそう）を拾えず、
    // `folder.badge.person.crop` のような点を含むシンボル名が鍵と誤認される。
    //
    // 見落とし（＝本物の鍵を見逃す）方向へ倒れないよう、宣言の形は
    // `var systemImage: String` / `var systemName: String` に限定して判定する。
    var braceDepth = 0
    var symbolMemberDepth: Int?
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let text = String(line)
        let depthBefore = braceDepth
        braceDepth += text.filter { $0 == "{" }.count - text.filter { $0 == "}" }.count
        defer {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if symbolMemberDepth == nil,
               trimmed.hasPrefix("var systemImage: String") || trimmed.hasPrefix("var systemName: String"),
               braceDepth > depthBefore {
                symbolMemberDepth = depthBefore
            } else if let depth = symbolMemberDepth, braceDepth <= depth {
                symbolMemberDepth = nil
            }
        }
        if symbolMemberDepth != nil { continue }
        let range = NSRange(text.startIndex..., in: text)
        for match in keyPattern.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            guard let prefix = key.split(separator: ".").first.map(String.init),
                  knownPrefixes.contains(prefix),
                  !defined.contains(key)
            else { continue }
            // **鍵に見えるだけの別物を除く。** SF Symbol 名（`folder.badge.plus`）
            // やファイル名（`diagnostics.json`）は、たまたま同じ形をしている。
            let before = String(text[text.startIndex..<keyRange.lowerBound])
            // `before` は開き引用符まで含む（捕捉は引用符の内側のため）。
            let isSymbolArgument = ["systemImage: \"", "systemName: \"", "systemImage:\"", "systemName:\""]
                .contains { before.hasSuffix($0) }
            let looksLikeFileName = [".json", ".log", ".plist", ".zip", ".txt", ".swift", ".dmg"]
                .contains { key.hasSuffix($0) }
            guard !isSymbolArgument, !looksLikeFileName else { continue }
            missing.append((key, path, index + 1))
        }
    }
}

if missing.isEmpty {
    print("==> OK: すべての文字列カタログの鍵が定義されている")
    exit(0)
}
print("==> FAIL: 定義されていない鍵が \(missing.count) 件あります（そのまま画面に出ます）")
for entry in missing.sorted(by: { $0.key < $1.key }) {
    print("  \(entry.key)  — \(entry.file):\(entry.line)")
}
exit(1)
