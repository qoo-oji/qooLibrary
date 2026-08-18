#!/usr/bin/env swift
//
// **公開されている面**に、到達不能になったはずの履歴が残っていないかを検査する
// [MT-30]。
//
// ## なぜローカルの検査だけでは足りないのか
//
// `check-private-data-leak.swift` を含め、既存の検査はすべて**手元のクローン**を
// 見る。ところが `git log --all` が見るのは到達可能なオブジェクトだけで、
// **force-push で到達不能になった履歴は映らない**。手元では消えたように見える。
//
// **GitHub は到達不能になったオブジェクトを、ハッシュ直指定で配信し続ける。**
// 実測（2026-08）: MT-28 で `git filter-repo` ＋ force-push を行い「除去完了」と
// 判断した 4 ブランチの旧先端が、その後も 4 本とも API から取得できた。旧履歴の
// ファイル内容には実名が 7 種・40 箇所以上残っていた。
//
// つまり**書き換え後のツリーを走査する検査は、露出の有無に関わらず必ず OK を
// 返す**。安心の根拠にならないのに、安心の根拠として使われていた。
//
// ## この検査が見るもの
//
// GitHub の Activity API から force-push の `before` SHA を集め、**それらが
// 到達できない（404）こと**を確かめる。取得できてしまったら、その履歴は今も
// 公開されている。
//
// **秘密を含む履歴を force-push で消したつもりになってはならない** [MT-30]。
// 公開ホストへ一度 push した秘密は、書き換えでは消えない——既定の対処は
// リポジトリの作り直し（またはホスト側サポートへの削除依頼）である。
//
// Usage: swift Scripts/check-published-history.swift [<owner/repo>]
//
// `gh` の認証が要る。認証が無い環境では検査せずに終了する（CI 用ではない）。

import Foundation

func run(_ arguments: [String]) -> (out: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ("", 127) }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (out, process.terminationStatus)
}

let slug: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    let remote = run(["git", "remote", "get-url", "origin"]).out
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // https://github.com/owner/repo.git / git@github.com:owner/repo.git
    guard let range = remote.range(of: "github.com") else { return "" }
    return String(remote[range.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        .replacingOccurrences(of: ".git", with: "")
}()

guard !slug.isEmpty else {
    print("==> origin が GitHub ではないので検査しない")
    exit(0)
}

let probe = run(["gh", "auth", "status"])
guard probe.status == 0 else {
    print("==> gh の認証が無いので検査しない（CI 用ではない。手元で走らせること）")
    exit(0)
}

// force-push の before SHA ＝「消したはずの履歴の先端」。
let activity = run([
    "gh", "api", "repos/\(slug)/activity?per_page=100",
    "--jq", #".[] | select(.activity_type=="force_push") | "\(.timestamp) \(.ref) \(.before)""#,
])
let events = activity.out.split(separator: "\n").map(String.init)
    .filter { !$0.isEmpty }

guard !events.isEmpty else {
    print("==> OK: force-push の記録が無い（消し残しの心配も無い）")
    exit(0)
}

var reachable: [(when: String, ref: String, sha: String)] = []
for line in events {
    let parts = line.split(separator: " ").map(String.init)
    guard parts.count >= 3 else { continue }
    let (when, ref, sha) = (parts[0], parts[1], parts[2])
    // 全ゼロは「ブランチ作成」で、消すべき履歴ではない。
    guard sha.contains(where: { $0 != "0" }) else { continue }
    let hit = run(["gh", "api", "repos/\(slug)/commits/\(sha)", "--jq", ".sha"])
    if hit.status == 0, !hit.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reachable.append((when, ref, sha))
    }
}

print("==> force-push の記録 \(events.count) 件を照合した（\(slug)）")
if reachable.isEmpty {
    print("==> OK: 消したはずの履歴はどれも公開されていない [MT-30]")
    exit(0)
}

// **SHA は表示するが、これは手元での確認用**。公開リポジトリの
// ファイルへ書き戻さないこと——旧データへの道案内そのものになる。
print("!! 消したはずの履歴が今も公開されている [MT-30]:")
for r in reachable {
    print("  ★ \(r.ref) の \(r.when) 以前の履歴（先端 \(r.sha.prefix(8))…）")
}
print("""

  **force-push では消えない。** 公開ホストへ一度 push した秘密は、
  書き換えでは除去できない。対処は次のいずれか:

    A. ホスト側サポートへ到達不能オブジェクトの削除を依頼する
    B. リポジトリを削除して作り直す（fork・star・Issue が少ないうちは安価）

  どちらも外部に影響するので、実行前に必ず持ち主の判断を仰ぐこと。
""")
exit(1)
