#!/usr/bin/env swift
//
// 実蔵書の固有名詞がリポジトリへ混入していないかを検査する [MT-28][B-14b]。
//
// **リポジトリは公開されている。**実在の作品名・作者名・サークル名を含む
// サンプルは `Tests/GoldenDataset/private/` に置き `.gitignore` する、という
// 明示的な指示がある。テストの標本を「実データの形」にする方針
// （CLAUDE.md の教訓）と両立させるには、**形は真似ても中身は借りない**必要がある。
//
// ## 走査は「厳密な部分文字列探索」でなければならない [設計判断]
//
// 最初の版は、コーパス側とリポジトリ側の**双方に同じ抽出器を通し、集合の積**を
// 取っていた。これは構造的に穴が開く——リポジトリ側の抽出器が作らない形の語は
// 永久に当たらない。実際、サークル名 1 件（カタカナ 2 文字＋ひらがな＋漢字 1 文字）が
// この穴を通り抜けた。抽出器の閾値（カタカナ 4 文字以上・漢字 3 文字以上）の
// どれにも当てはまらず、リポジトリ側では全角括弧とバッククォートの中にあって
// 半角括弧しか見ない抽出器に拾われなかったためである。
//
// **抽出はコーパス側だけで行い、リポジトリ側は全文をそのまま走査する。**
// 素朴に「語ごとに全ファイルを探索」すると語数 × ファイル数になり実用にならないので、
// 先頭 2 スカラーをキーにしたバケット索引で 1 パスに畳んでいる（実測 4 秒台）。
//
// ## 部分一致の誤検出は「同種文字の連なり」で切る
//
// 厳密な部分文字列探索は、一般語の一部に当たってしまう（`ブロッカー` の中の
// `ロッカー`、`消化計画` の中の `化計画`、英単語の中に埋もれた短い綴り）。
// そこで**前後が同じ種類の文字なら採らない**。逆に、実在名の直後が ASCII や
// 記号であれば——長い作品名の一部が独立した語として現れていれば——採る。
// 実在名の一部を取りこぼした過去の失敗（変異検証で判明）はこれで塞がる。
//
// **この注記自体に実名を書かないこと。**除去の説明の中へ秘密を写す事故は、
// このリポジトリで 3 度起きている（3 度目はこの検査自身が即座に捕まえた）。
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
    /// **登録フォルダ自身の表示名**。`entries` は根からの相対パスなので、
    /// **根の名前はどのエントリにも現れない**——ここを読まないと、
    /// ライブラリ／テンポラリフォルダの名前が検査の死角に入る [MT-31]。
    /// 実際、実在のフォルダ名が CLAUDE.md に 3 箇所残っているのを
    /// この穴が見逃していた。
    let libraryName: String
}

// MARK: - 文字の種別（誤検出を切るための境界判定に使う）

enum ScriptClass { case katakana, hiragana, kanji, alnum, other }

func scriptClass(_ s: Unicode.Scalar) -> ScriptClass {
    switch s.value {
    case 0x30A0...0x30FF, 0xFF66...0xFF9F: return .katakana   // 片仮名（半角含む）
    case 0x3040...0x309F: return .hiragana
    case 0x4E00...0x9FFF, 0x3005: return .kanji
    default:
        if ("a"..."z").contains(String(s)) || ("A"..."Z").contains(String(s))
            || ("0"..."9").contains(String(s)) { return .alnum }
        if s.value >= 0xFF10 && s.value <= 0xFF5A { return .alnum } // 全角英数
        return .other
    }
}

// MARK: - コーパスから固有名詞を集める（抽出はこちら側でのみ行う）

let bracket = try! NSRegularExpression(
    pattern: "[\\[\\(［（【]([^\\[\\]\\(\\)［］（）【】]{3,})[\\]\\)］）】]")
let katakanaRun = try! NSRegularExpression(pattern: "[ァ-ヶー]{4,}")
let kanjiRun = try! NSRegularExpression(pattern: "[一-龠]{3,}")
let anyBracketed = try! NSRegularExpression(
    pattern: "[\\[\\(【「（［][^\\[\\]\\(\\)【】「」（）［］]*[\\]\\)】」）］]")

func addRuns(_ text: String, into out: inout Set<String>) {
    let range = NSRange(text.startIndex..., in: text)
    for regex in [katakanaRun, kanjiRun] {
        for m in regex.matches(in: text, range: range) {
            if let r = Range(m.range, in: text) { out.insert(String(text[r])) }
        }
    }
}

var nouns: Set<String> = []
var entryCount = 0
for file in corpusFiles where file.pathExtension == "json" {
    guard let data = try? Data(contentsOf: file),
          let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else { continue }
    // 登録フォルダ自身の名前 [MT-31]。フォルダ名も保護対象である
    // ［ユーザー判断: ボリューム名・機材構成は許容するが、ファイル名と
    // フォルダ名は許容できない］。
    let libraryName = corpus.libraryName.precomposedStringWithCanonicalMapping
    if libraryName.count >= 3 { nouns.insert(libraryName) }
    addRuns(libraryName, into: &nouns)
    for entry in corpus.entries {
        let name = (entry.relativePath as NSString).lastPathComponent
        let stem = ((name as NSString).deletingPathExtension)
            .precomposedStringWithCanonicalMapping
        entryCount += 1
        // 括弧の中身（サークル名・作者名・原作名）
        let range = NSRange(stem.startIndex..., in: stem)
        for m in bracket.matches(in: stem, range: range) {
            guard let r = Range(m.range(at: 1), in: stem) else { continue }
            for part in stem[r].split(whereSeparator: { "()（）".contains($0) }) {
                let token = part.trimmingCharacters(in: .whitespaces)
                if token.count >= 3 { nouns.insert(token) }
            }
        }
        // 括弧の外（作品タイトル）
        let outside = anyBracketed.stringByReplacingMatches(
            in: stem, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
        if outside.count >= 6 { nouns.insert(outside) }
        addRuns(stem, into: &nouns)
    }
}

/// 実蔵書のファイル名にも現れるが、日本語・英語の一般語であって固有名詞ではないもの。
/// **ここへ実在の作品名を足すと検査が無意味になる。**足すのは、辞書に載る一般語だけ。
let generic: Set<String> = [
    "成年コミック", "同人CG集", "同人CG", "同人誌", "一般コミック", "コミック", "オリジナル",
    "サークル", "シリーズ", "作品集", "完全版", "完結編", "総集編", "番外編", "単行本",
    "新装版", "上下巻", "その他", "セット", "バージョン", "ファイル", "フォルダ",
    "オーバーロード", "オンライン", "コントロール", "サポート", "サービス", "ショートカット",
    "センター", "ドキュメント", "パーティ", "プログラム", "プロジェクト", "マネージャー",
    "ミッション", "メディア", "レイヤー", "フェイス", "ハンター", "アーカイブ", "クリーン",
    "トラップ", "スイート", "システム", "ドロップ", "イベント", "プール", "アプリ", "リスク",
    "レベル", "スイッチ", "コネクション", "ロッカー", "大丈夫", "潜在的", "設定以外", "化計画",
    // 英語の一般語。ローマ字表記のファイル名から抽出されるが辞書語である。
    // コミットログを走査対象に加えた [MT-29] ことで当たるようになった
    // （"archive preview doubles as the placeholder" の doubles）。
    "doubles",
]

let targets = nouns.subtracting(generic).filter { $0.count >= 3 }

// MARK: - バケット索引（先頭 2 スカラー）

struct Needle { let scalars: [Unicode.Scalar]; let text: String }

var buckets: [UInt64: [Needle]] = [:]
func key(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> UInt64 {
    (UInt64(a.value) << 32) | UInt64(b.value)
}
for name in targets {
    let s = Array(name.unicodeScalars)
    guard s.count >= 2 else { continue }
    buckets[key(s[0], s[1]), default: []].append(Needle(scalars: s, text: name))
}

// MARK: - 走査

func run(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return out
}

var suspects: [String: [String]] = [:]

/// 1 つの本文を照合する。`origin` は違反時に示す出どころ。
func scan(_ raw: String, origin: String) {
    let hay = Array(raw.precomposedStringWithCanonicalMapping.unicodeScalars)
    guard hay.count >= 2 else { return }
    for i in 0..<(hay.count - 1) {
        guard let bucket = buckets[key(hay[i], hay[i + 1])] else { continue }
        for needle in bucket {
            let n = needle.scalars.count
            guard i + n <= hay.count else { continue }
            var ok = true
            for k in 2..<n where hay[i + k] != needle.scalars[k] { ok = false; break }
            guard ok else { continue }
            // 前後が同じ種類の文字なら、より長い一般語の一部とみなして採らない。
            if i > 0, scriptClass(hay[i - 1]) == scriptClass(needle.scalars[0]) { continue }
            if i + n < hay.count,
               scriptClass(hay[i + n]) == scriptClass(needle.scalars[n - 1]) { continue }
            suspects[needle.text, default: []].append(origin)
        }
    }
}

// ① 追跡ファイル
let files = run(["git", "-C", repoRoot.path, "ls-files"])
    .split(separator: "\n").map(String.init)
var scannedFiles = 0
for relative in files where !relative.hasPrefix("Tests/GoldenDataset/private/") {
    let url = repoRoot.appendingPathComponent(relative)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
    scannedFiles += 1
    scan(raw, origin: relative)
}

// ② コミットログ [MT-29]
//
// **ファイルだけを見ていては足りない。** リポジトリを公開するとは、
// 履歴を公開することでもある。実際、MT-28 の履歴書き換えでは
// `--message-callback` でメッセージ側も対象にしており、**メッセージが
// 漏洩経路であることは分かっていたのに、以後の検査には入っていなかった。**
//
// 著者名・日付は対象にしない（実蔵書の固有名詞とは別の関心事）。
let logSeparator = "\u{1}"
let messages = run([
    "git", "-C", repoRoot.path, "log", "--all", "--format=%H%n%B\(logSeparator)",
])
var scannedCommits = 0
for chunk in messages.components(separatedBy: logSeparator) {
    let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { continue }
    let hash = String(body.prefix(40))
    scannedCommits += 1
    scan(body, origin: "コミット \(hash.prefix(8))")
}

// ③ タグとブランチの名前（人が付ける文字列なので実名が入りうる）
let refs = run(["git", "-C", repoRoot.path, "for-each-ref", "--format=%(refname)"])
scan(refs, origin: "ref 名")

let violations = suspects.sorted { $0.key < $1.key }.map { (name: $0.key, files: Array(Set($0.value)).sorted()) }

print("==> 実蔵書 \(entryCount) 件から固有名詞 \(targets.count) 種を取り、追跡ファイル \(scannedFiles) 件・コミット \(scannedCommits) 件・ref 名を全文照合した")
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
  一般語が誤検出されたときだけ `generic` へ足す。**実在名を足してはならない。**
  """)
exit(1)
