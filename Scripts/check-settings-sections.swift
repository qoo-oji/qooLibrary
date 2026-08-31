#!/usr/bin/env swift
//
// CI static check [§19.7][P3]: `LibrarySettingsSection` の全 case は
// `standard`（通常時に中央ペインへ並ぶ）か `advanced`（「高度な設定…」の
// 中だけに現れる）の**どちらか一方**にちょうど 1 度現れなければならない。
//
// Usage: swift Scripts/check-settings-sections.swift
//
// ## なぜ機械的に検査するのか
// 分類を忘れた case は**どこからも到達できない設定**になる——中央ペインにも
// ダイアログにも行が無く、`switch` は網羅しているのでコンパイルは通り、
// テストも落ちない。利用者から見れば「その設定は存在しない」のと同じで、
// しかも保存済みの値だけが効き続けるので、原因の分かりにくい形になる。
//
// 逆に両方へ入れると、同じ設定が 2 箇所に現れる（設定ウインドウの中央ペインと
// ダイアログの両方）。どちらの穴も、レビューでは見落としやすく機械なら確実に
// 捕まえられる。
//
// このコードは `qooLibraryApp`（アプリターゲット）にあり `swift test` からは
// 触れないため、単体テストではなく静的検査で守る。
//
// Note: 単純なテキストスキャンであり、Swift の完全な構文解析はしない
// （他の静的検査と同じ方針。レビュー漏れの機械的検出には十分）。

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let target = repoRoot
    .appendingPathComponent("Sources/qooLibraryApp/LibrarySettings/LibrarySettingsModel.swift")

guard let source = try? String(contentsOf: target, encoding: .utf8) else {
    FileHandle.standardError.write(
        Data("error: \(target.path) を読めませんでした\n".utf8))
    exit(1)
}

/// `enum LibrarySettingsSection` の宣言本体（最初の `}` が独立した行まで）。
func enumBody(in source: String) -> [Substring]? {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    guard let start = lines.firstIndex(where: {
        $0.hasPrefix("enum LibrarySettingsSection")
    }) else { return nil }
    guard let end = lines[start...].firstIndex(where: { $0 == "}" }) else { return nil }
    return Array(lines[start...end])
}

guard let body = enumBody(in: source) else {
    FileHandle.standardError.write(Data("error: enum LibrarySettingsSection が見つかりません\n".utf8))
    exit(1)
}

/// `case a, b, c` の行から case 名を集める。関連値は使っていない前提。
var declared: [String] = []
for line in body {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("case ") else { continue }
    // `switch` の中の `case .basics:` は除く（宣言は `.` を持たない）。
    guard !trimmed.contains(".") else { continue }
    let names = trimmed.dropFirst("case ".count)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
    declared.append(contentsOf: names)
}

/// `static let standard: [Self] = [...]` の中の `.name` を集める。
func members(of listName: String, in body: [Substring]) -> [String]? {
    guard let start = body.firstIndex(where: {
        $0.contains("static let \(listName): [Self]")
    }) else { return nil }
    // 宣言が複数行にまたがることがあるので、代入の右辺が閉じるまで連結する。
    // **`]` の有無だけで打ち切らない**——型注釈の `[Self]` に釣られて、
    // 先頭の要素を落とす（実際にこれで検査が空振りしかけた）。
    var text = ""
    for line in body[start...] {
        text += line
        if let assign = text.range(of: "= ["),
           text[assign.upperBound...].contains("]") { break }
    }
    guard let assign = text.range(of: "= ") else { return nil }
    let rest = text[assign.upperBound...]
    guard let open = rest.firstIndex(of: "["), let close = rest.firstIndex(of: "]"),
          open < close else { return nil }
    return rest[rest.index(after: open)..<close]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix(".") }
        .map { String($0.dropFirst()) }
}

guard let standard = members(of: "standard", in: body),
      let advanced = members(of: "advanced", in: body) else {
    FileHandle.standardError.write(
        Data("error: standard / advanced の宣言を読み取れません\n".utf8))
    exit(1)
}

var violations: [String] = []

if declared.isEmpty {
    violations.append("case を 1 つも読み取れませんでした（宣言の書き方が変わった可能性）")
}

for name in declared {
    let inStandard = standard.contains(name)
    let inAdvanced = advanced.contains(name)
    if !inStandard && !inAdvanced {
        violations.append("`\(name)` が standard にも advanced にも入っていません"
                          + "（どこからも到達できない設定になります）")
    }
    if inStandard && inAdvanced {
        violations.append("`\(name)` が standard と advanced の両方に入っています"
                          + "（同じ設定が 2 箇所に現れます）")
    }
}

for name in standard + advanced where !declared.contains(name) {
    violations.append("`\(name)` は宣言されていない case です")
}

if violations.isEmpty {
    print("✅ 設定セクションの分類 OK "
          + "(通常 \(standard.count) / 高度 \(advanced.count) / 全 \(declared.count))")
    exit(0)
}

FileHandle.standardError.write(Data("❌ 設定セクションの分類に不備があります [§19.7]:\n".utf8))
for v in violations {
    FileHandle.standardError.write(Data("  - \(v)\n".utf8))
}
exit(1)
