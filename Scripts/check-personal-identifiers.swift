#!/usr/bin/env swift
//
// **貢献者自身の環境**に由来する名前がリポジトリへ入っていないかを検査する [MT-32]。
//
// ## なぜゴールデンコーパスの検査だけでは足りないのか
//
// `check-private-data-leak.swift` は `Tests/GoldenDataset/private/corpus/` を
// 必要とする。**これは持ち主にしか無い。**引き継いだ人・共同作業者は自分の蔵書を
// 持つが、その名前は誰のコーパスにも載らない——**新しい貢献者ほど保護が薄い**という、
// 引き継ぎを前提とするこのプロジェクトでは受け入れられない性質だった。
//
// ここは**コーパスを必要としない**。検出対象を**動いている環境そのもの**から取る:
//
//   - アプリが保存している登録フォルダの表示名（`registeredFolders.json`）
//   - ユーザー名とホームディレクトリのパス
//
// 実際、実在のフォルダ名が CLAUDE.md に 3 箇所残っていたのを、コーパス側の検査は
// 見逃していた（`libraryName` を読んでいなかったため [MT-31]）。**同じ名前は
// アプリの登録情報にも載っており、こちらなら捕まえられた。**独立した情報源から
// 二重に見るのが要点である。
//
// ## 保護の範囲［ユーザー判断］
//
// **ボリューム名と機材構成は保護対象外。ファイル名とフォルダ名は保護対象。**
// したがって `/Volumes/<ボリューム名>` は許すが、その下のフォルダ名は許さない。
//
// Usage: swift Scripts/check-personal-identifiers.swift

import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

func run(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return out
}

// MARK: - 検出対象を環境から集める

var targets: [String: String] = [:]   // 名前 → 何に由来するか

/// アプリが保存している登録フォルダ（ライブラリ／テンポラリ）の表示名。
/// **今回漏れたのはまさにこれ。**
let store = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
        "Library/Containers/com.qoolibrary.app/Data/Library/Application Support/qooLibrary/registeredFolders.json")

/// **最上位は配列**（`[{ id, kind, displayName, bookmarkData, lastKnownPath }, …]`）。
/// 一度 `{ "folders": [...] }` を期待して書いたところ、デコードに黙って失敗し、
/// **「登録情報を使った」と表示しながら 1 件も読まずに OK を返していた**
/// ——この検査が防ごうとしているのと同じ失敗である。だから下では
/// **「ファイルはあるのに 0 件」を成功として扱わない。**
struct StoredFolder: Decodable {
    let displayName: String
    let lastKnownPath: String?
}

var sawStore = false
var storeUnreadable = false
if let data = try? Data(contentsOf: store) {
    sawStore = true
    var found = 0
    if let decoded = try? JSONDecoder().decode([StoredFolder].self, from: data) {
        for folder in decoded {
            targets[folder.displayName] = "登録フォルダの表示名"
            // 表示名は変更できるので、ディスク上の実際のフォルダ名は別に押さえる。
            if let path = folder.lastKnownPath {
                let onDisk = (path as NSString).lastPathComponent
                if onDisk != folder.displayName { targets[onDisk] = "登録フォルダの実名" }
            }
            found += 1
        }
    }
    if found == 0 { storeUnreadable = true }
}

if storeUnreadable {
    FileHandle.standardError.write(Data("""
        !! 登録フォルダの一覧を読めなかった [MT-32]。形式が変わった可能性がある。
           **「読めなかった」を「問題なし」と読み替えないこと。**この検査は
           まさにその取り違えを防ぐためにある。

        """.utf8))
    exit(2)
}

let userName = run(["whoami"]).trimmingCharacters(in: .whitespacesAndNewlines)
if userName.count >= 3 { targets[userName] = "ユーザー名" }
let realHome = FileManager.default.homeDirectoryForCurrentUser.path
if realHome.hasPrefix("/Users/") { targets[realHome] = "ホームのパス" }

// **ボリューム名は対象にしない**［ユーザー判断: 機材構成の秘匿は求めない］。

/// ごく一般的で、固有名詞として扱うと誤検出になるもの。
/// **ここへ実在の名前を足すと検査が無意味になる。**
let generic: Set<String> = [
    "Documents", "Downloads", "Desktop", "Library", "Movies", "Music", "Pictures",
    "Public", "Applications", "Users", "Volumes", "Shared", "Comics", "Books",
]
for key in generic { targets.removeValue(forKey: key) }

// **プロジェクト自身の語彙は除外する**——ジャンル名で自分のライブラリを
// 名づけると（`同人誌` フォルダに同人誌を入れる、など）、その語はプリセットの
// ライブラリタイプ名として**リポジトリに必ず存在する**。これは漏洩ではない。
//
// **手書きの除外リストへ足さず、テンプレート定義から導く。**手で足す運用に
// すると、いつか実名が紛れ込んで検査が黙って無意味になる——除外は
// 「プロジェクトが元から持っている語」に限られるべきで、その判断は
// 人ではなくファイルにさせる。
let templates = repoRoot
    .appendingPathComponent("Sources/QooKit/Resources/Templates/library-types.json")
if let data = try? Data(contentsOf: templates),
   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let presets = root["presets"] as? [[String: Any]] {
    var vocabulary: Set<String> = []
    for preset in presets {
        for key in ["libraryTypeName", "displayName"] {
            if let value = preset[key] as? String { vocabulary.insert(value) }
        }
    }
    for name in targets.keys where vocabulary.contains(where: { $0.contains(name) }) {
        targets.removeValue(forKey: name)
    }
}
targets = targets.filter { $0.key.count >= 3 }

guard !targets.isEmpty else {
    // **黙って通さない。**検査できないことは「安全」ではない。
    FileHandle.standardError.write(Data("""
        !! 環境から検出対象を 1 つも取れなかったため検査できない [MT-32]。
           アプリを一度起動して登録フォルダを作るか、この検査を見直すこと。
           **「検査できなかった」を「問題なし」と読み替えないこと。**

        """.utf8))
    exit(2)
}

// MARK: - 走査

var suspects: [String: [String]] = [:]

func scan(_ raw: String, origin: String) {
    let hay = raw.precomposedStringWithCanonicalMapping
    for (name, _) in targets where hay.contains(name.precomposedStringWithCanonicalMapping) {
        suspects[name, default: []].append(origin)
    }
}

let files = run(["git", "-C", repoRoot.path, "ls-files"])
    .split(separator: "\n").map(String.init)
var scanned = 0
for relative in files where !relative.hasPrefix("Tests/GoldenDataset/private/") {
    guard let raw = try? String(contentsOf: repoRoot.appendingPathComponent(relative),
                                encoding: .utf8) else { continue }
    scanned += 1
    scan(raw, origin: relative)
}
// コミットログと ref 名も同じ経路 [MT-29]。
scan(run(["git", "-C", repoRoot.path, "log", "--all", "--format=%B"]), origin: "コミットログ")
scan(run(["git", "-C", repoRoot.path, "for-each-ref", "--format=%(refname)"]), origin: "ref 名")

let source = sawStore ? "アプリの登録情報＋アカウント情報" : "アカウント情報のみ（アプリ未起動）"
print("==> 環境から \(targets.count) 種の識別子を取り（\(source)）、追跡ファイル \(scanned) 件・コミットログ・ref 名を照合した")

if suspects.isEmpty {
    print("==> OK: 貢献者自身の環境に由来する名前は含まれていない [MT-32]")
    exit(0)
}

// **名前そのものを出力しない。**検査の出力もまた漏洩経路になりうる
// （このリポジトリでは「除去の説明の中へ秘密を写す」事故が実際に 3 度起きている）。
print("!! 環境に由来する名前がリポジトリに含まれている [MT-32]:")
for (name, origins) in suspects.sorted(by: { $0.key < $1.key }) {
    let kind = targets[name] ?? "不明"
    print("  ★ \(kind)（\(name.count) 文字）が \(Set(origins).count) 箇所")
    for origin in Array(Set(origins)).sorted().prefix(5) { print("      \(origin)") }
}
print("""

  合成名へ置き換えること。**実名を伏せて表示しているのは意図的**で、
  検査の出力もまた漏洩経路になりうるため。該当箇所は上のファイルを
  自分で開いて確認すること。
""")
exit(1)
