#!/usr/bin/env swift
//
// 実蔵書の固有名詞がリポジトリへ混入していないかを検査する [MT-28][B-14]。
//
// **リポジトリは公開されている。**実在の作品名・作者名・サークル名を含む
// サンプルは `Tests/GoldenDataset/private/` に置き `.gitignore` する、という
// 明示的な指示がある。テストの標本を「実データの形」にする方針
// （CLAUDE.md の教訓）と両立させるには、**形は真似ても中身は借りない**必要がある。
//
// 実際、フェーズ 2 の点検で実在のサークル名 1 件・作品名 2 件が
// 追跡ファイルに入っていたことが判明した（フェーズ 1 で混入し push 済みだった）。
//
// コーパス（`Tests/GoldenDataset/private/corpus/`）が無い環境では何もしない。
// CI では走らない——コーパスがそこに無いため。**手元でコミット前に走らせること。**
//
// Usage: swift Scripts/check-private-data-leak.swift

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let corpusDir = repoRoot.appendingPathComponent("Tests/GoldenDataset/private/corpus")

guard let corpusFiles = try? FileManager.default.contentsOfDirectory(
    at: corpusDir, includingPropertiesForKeys: nil), !corpusFiles.isEmpty else {
    print("==> 実コーパスが無いので検査しない（Scripts/extract-golden-corpus.swift で作る）")
    exit(0)
}

struct Corpus: Decodable {
    struct Entry: Decodable { let relativePath: String; let isDirectory: Bool }
    let entries: [Entry]
}

/// 実蔵書のファイル名から固有名詞を集める。
/// 括弧の中身（サークル名・作者名・原作名）と、括弧の外（作品タイトル）。
let bracket = try! NSRegularExpression(pattern: "[\\[\\(]([^\\[\\]\\(\\)]{3,})[\\]\\)]")

func properNouns(from files: [URL]) -> Set<String> {
    var out: Set<String> = []
    let stripBrackets = try! NSRegularExpression(pattern: "[\\[\\(【「][^\\[\\]\\(\\)【】「」]*[\\]\\)】」]")
    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else { continue }
        for entry in corpus.entries where !entry.isDirectory {
            let name = (entry.relativePath as NSString).lastPathComponent
                .precomposedStringWithCanonicalMapping
            let stem = (name as NSString).deletingPathExtension
            let range = NSRange(stem.startIndex..., in: stem)

            for match in bracket.matches(in: stem, range: range) {
                guard let r = Range(match.range(at: 1), in: stem) else { continue }
                for part in stem[r].split(whereSeparator: { "()（）".contains($0) }) {
                    let token = part.trimmingCharacters(in: .whitespaces)
                    if token.count >= 4 { out.insert(token) }
                }
            }
            let outside = stripBrackets
                .stringByReplacingMatches(in: stem, range: range, withTemplate: " ")
                .trimmingCharacters(in: .whitespaces)
            if outside.count >= 6 { out.insert(outside) }
            // まるごとのトークンに加え、固有名詞になりやすい連なりも拾う。
            out.formUnion(runs(in: stem))
        }
    }
    return out
}

/// 実蔵書にも現れるが**一般語**であり、リポジトリに出ても問題ないもの。
///
/// **ここへ足すときは「本当に一般語か」を必ず確かめること。**実在の作品名を
/// 足してしまうと、この検査そのものが無意味になる。迷ったら足さずに、
/// テスト側の標本を合成名へ変える。
let generic: Set<String> = [
    // ライブラリ種別・分類
    "成年コミック", "同人CG集", "同人CG", "同人誌", "一般コミック", "コミック",
    "オリジナル", "サークル", "シリーズ", "作品集",
    // 巻数・版の表記
    "完全版", "完結編", "総集編", "番外編",
    // 技術用語・UI 用語
    "オーバーロード", "オンライン", "コントロール", "サポート", "サービス",
    "ショートカット", "センター", "ドキュメント", "パーティ", "プログラム",
    "プロジェクト", "マネージャー", "ミッション", "メディア", "レイヤー",
    "フェイス", "ハンター", "大丈夫", "潜在的", "設定以外",
]

/// 日本語の固有名詞になりやすい連なり。**まるごとのトークンだけを見ると
/// 取りこぼす**——実在名の一部（`作品A` の中の `バグベア`）を標本に
/// 使ってしまう事故が実際にあり得る（変異検証で確認した）。
let katakanaRun = try! NSRegularExpression(pattern: "[ァ-ヶー]{4,}")
let kanjiRun = try! NSRegularExpression(pattern: "[一-龠]{3,}")

func runs(in text: String) -> Set<String> {
    var out: Set<String> = []
    let range = NSRange(text.startIndex..., in: text)
    for regex in [katakanaRun, kanjiRun] {
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) { out.insert(String(text[r])) }
        }
    }
    return out
}

let nouns = properNouns(from: corpusFiles)
    .filter { !generic.contains($0) && !$0.allSatisfy(\.isASCII) }

let tracked = (try? String(contentsOf: URL(fileURLWithPath: "/dev/stdin"), encoding: .utf8)) ?? ""
_ = tracked
let listed = Process()
listed.executableURL = URL(fileURLWithPath: "/usr/bin/env")
listed.arguments = ["git", "-C", repoRoot.path, "ls-files"]
let pipe = Pipe()
listed.standardOutput = pipe
try listed.run()
let files = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .split(separator: "\n").map(String.init)
listed.waitUntilExit()

// **リポジトリ側からも同じ種類の語を抽出して、集合の積を取る。**
// 語ごとに全ファイルを部分文字列探索すると 3,900 × 369 回になり実用にならない
// （実際に 10 分で終わらなかった）。抽出は 1 パスで済む。
var suspects: [String: [String]] = [:]
var scannedFiles = 0

for relative in files where !relative.hasPrefix("Tests/GoldenDataset/private/") {
    let url = repoRoot.appendingPathComponent(relative)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
    scannedFiles += 1
    let text = raw.precomposedStringWithCanonicalMapping
    var tokens = runs(in: text)
    // 角括弧・丸括弧の中身も拾う（テストの標本はこの形で書かれる）
    let range = NSRange(text.startIndex..., in: text)
    for match in bracket.matches(in: text, range: range) {
        guard let r = Range(match.range(at: 1), in: text) else { continue }
        for part in text[r].split(whereSeparator: { "()（）".contains($0) }) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.count >= 4 { tokens.insert(token) }
        }
    }
    for token in tokens where nouns.contains(token) {
        suspects[token, default: []].append(relative)
    }
}

let violations = suspects.sorted { $0.key < $1.key }.map { (name: $0.key, files: $0.value) }

print("==> 実蔵書由来の語 \(nouns.count) 種 × 追跡ファイル \(scannedFiles) 件を照合した")
if violations.isEmpty {
    print("==> OK: 実蔵書の固有名詞は含まれていない [MT-28]")
    exit(0)
}
print("!! 実蔵書の固有名詞がリポジトリに含まれている [MT-28]:")
for v in violations {
    print("  ★ \(v.name)")
    for f in v.files.prefix(6) { print("      \(f)") }
}
print("""

  テストの標本は「実データの**形**」にすること。中身は借りない——
  同じ形の合成名（例: `98765架空社` `サンプルプレビュー`）に置き換える。
  置き換え候補がコーパスに無いことを、このスクリプトで確かめてから使う。
  """)
exit(1)
