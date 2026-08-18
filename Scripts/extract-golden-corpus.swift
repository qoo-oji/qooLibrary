#!/usr/bin/env swift
//
// ゴールデンサンプル収集の導線 [MT-27][DP-09][GT-05 の前段]。
//
// 登録済みライブラリ／テンポラリフォルダを走査し、**ファイル名と相対パスだけ**を
// `Tests/GoldenDataset/private/corpus/<表示名>.json` に書き出す。ファイルの中身には
// 一切触れない（`FileManager` の列挙のみ）。
//
// 出力先は `.gitignore` 済みで、実ファイル名がリポジトリへ入ることはない [MT-28][B-14]。
// パーサ（04章）が完成したら、このコーパスから期待値付きのゴールデンケース
// （16章 §16.2 の形式）を生成し、人間が確認して確定させる [GT-03]。
//
// Usage: swift Scripts/extract-golden-corpus.swift [<登録フォルダJSONのパス>]

import Foundation

// MARK: - 出力形式

struct CorpusEntry: Codable {
    /// ライブラリ根からの相対パス（ディレクトリ部分を含む）。フォルダ階層ごとの
    /// ラベル割り当て [AL-01〜AL-03] の検証に必要なため、ファイル名だけにしない。
    let relativePath: String
    let isDirectory: Bool
    /// 直下の子の数。ブックフォルダ判定 [IF-01] の検証材料。
    let childCount: Int?
}

struct Corpus: Codable {
    let libraryName: String
    let kind: String
    /// 根そのもののパスは書き出さない（ユーザーのディレクトリ構成が漏れるため）。
    let entryCount: Int
    let extractedAt: Date
    let entries: [CorpusEntry]
}

// MARK: - 走査

/// 拡張子を持たない実ディレクトリのみ再帰する。パッケージ（.app 等）へは入らない。
func walk(root: URL) -> [CorpusEntry] {
    var out: [CorpusEntry] = []
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
    guard let e = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants, .skipsHiddenFiles]
    ) else { return [] }

    let rootPath = root.standardizedFileURL.path
    for case let url as URL in e {
        let v = try? url.resourceValues(forKeys: Set(keys))
        if v?.isSymbolicLink == true { continue }          // [SL-03]
        let isDir = v?.isDirectory ?? false
        var rel = url.standardizedFileURL.path
        guard rel.hasPrefix(rootPath + "/") else { continue }
        rel.removeFirst(rootPath.count + 1)

        var childCount: Int?
        if isDir {
            childCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                .filter { $0 != ".DS_Store" }.count
        }
        out.append(CorpusEntry(relativePath: rel, isDirectory: isDir, childCount: childCount))
    }
    return out.sorted { $0.relativePath < $1.relativePath }
}

// MARK: - 実行

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("Tests/GoldenDataset/private/corpus", isDirectory: true)

let defaultRegistry = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/com.qoolibrary.app/Data/Library/Application Support/qooLibrary/registeredFolders.json")
let registryURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultRegistry

struct RegisteredFolder: Decodable {
    let displayName: String
    let kind: String
    let lastKnownPath: String?
}

guard let data = try? Data(contentsOf: registryURL),
      let folders = try? JSONDecoder().decode([RegisteredFolder].self, from: data) else {
    FileHandle.standardError.write(Data("登録フォルダの一覧を読めない: \(registryURL.path)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601

var total = 0
for f in folders {
    guard let path = f.lastKnownPath,
          FileManager.default.fileExists(atPath: path) else {
        print("skip  \(f.displayName)  (到達できない)")
        continue
    }
    let entries = walk(root: URL(fileURLWithPath: path))
    let corpus = Corpus(libraryName: f.displayName, kind: f.kind,
                        entryCount: entries.count, extractedAt: Date(), entries: entries)
    let out = outDir.appendingPathComponent("\(f.displayName).json")
    try encoder.encode(corpus).write(to: out, options: .atomic)
    let files = entries.filter { !$0.isDirectory }.count
    print("ok    \(f.displayName)  files=\(files) dirs=\(entries.count - files)")
    total += entries.count
}
print("==> \(total) 件を \(outDir.path) へ書き出した（.gitignore 済み）")
