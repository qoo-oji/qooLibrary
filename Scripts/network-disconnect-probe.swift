// ネットワーク共有が「マウントされたまま到達できない」状態で何が起きるかを測る。
// `Scripts/network-disconnect-probe.sh` から呼ばれる。単体では使わない。
//
//   prepare <共有パス>   遮断する前に、ブックマークとプローブファイルを作る
//   measure <共有パス>   遮断中に測る
//   cleanup <共有パス>   後片付け
//
// **すべての計測を並行に走らせ、1 つの見張り時間で打ち切る。** 遮断している
// 時間を短くするため。ブロックしたスレッドは殺せないので（macOS に中断可能な
// ファイル I/O は無い [NV6-03]）、返らなかったものは報告だけしてプロセス終了に
// 任せる。

import AppKit
import CoreServices
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "measure"
let share = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/Volumes/Share"
let stateDir = NSTemporaryDirectory() + "qoo-disconnect-probe"
let bookmarkFile = stateDir + "/bookmark.dat"
let probeFileRecord = stateDir + "/probe-file.txt"
let mmapFileRecord = stateDir + "/probe-mmap-file.txt"
/// 項目 12（F3）用。**mmap は遮断の「前」に張る必要がある** — 遮断後に
/// `open` すると、そこで ETIMEDOUT になって mmap まで到達しない（最初の版が
/// これで、SIGBUS の問いに一度も答えられていなかった）。危ないのは
/// 「切断前に開いて写像済みのページが、切断後にフォルトする」場合である。
let mmapReadyFile = stateDir + "/mmap-ready"
let mmapGoFile = stateDir + "/mmap-go"
let mmapResultFile = stateDir + "/mmap-result"
let mmapPidFile = stateDir + "/mmap-pid"

/// SIGBUS ハンドラから書くための記述子。シグナルハンドラ内で使えるのは
/// async-signal-safe な関数だけなので、`write(2)` を直接使う。
nonisolated(unsafe) var mmapResultFD: Int32 = -1
/// 1 件でも返らないものがあったときに、いつまで待つか。SMB の
/// `max_resp_timeout` 既定が 30 秒なので、それを見届けられる長さにする。
let watchdogSeconds = 45

func posixName(_ e: Int32) -> String {
    let names: [Int32: String] = [
        ETIMEDOUT: "ETIMEDOUT", ENOTCONN: "ENOTCONN", ESTALE: "ESTALE",
        EHOSTDOWN: "EHOSTDOWN", EHOSTUNREACH: "EHOSTUNREACH", ENETDOWN: "ENETDOWN",
        ENETUNREACH: "ENETUNREACH", ECONNRESET: "ECONNRESET", ECONNABORTED: "ECONNABORTED",
        EIO: "EIO", ENODEV: "ENODEV", ENXIO: "ENXIO", EPERM: "EPERM", EACCES: "EACCES",
        ENOENT: "ENOENT", EINTR: "EINTR", EAGAIN: "EAGAIN", EBUSY: "EBUSY",
    ]
    return "\(names[e] ?? "errno")(\(e))"
}

switch mode {
case "prepare":
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let dir = URL(fileURLWithPath: share).appendingPathComponent(".qoo-probe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("probe.bin")
    try? Data(repeating: 0x51, count: 4096).write(to: file)
    try? file.path.write(toFile: probeFileRecord, atomically: true, encoding: .utf8)
    // mmap フォルト計測用（項目 12）。書いた直後はページがキャッシュに居るため、
    // bash 側が遮断後に `purge` してからフォルトさせる。
    let mmapFile = dir.appendingPathComponent("probe-mmap.bin")
    try? Data(repeating: 0x51, count: 8 * 1024 * 1024).write(to: mmapFile)
    try? mmapFile.path.write(toFile: mmapFileRecord, atomically: true, encoding: .utf8)
    // mmap を張ったまま遮断をまたぐ常駐プロセスを起こす（項目 12）。
    try? FileManager.default.removeItem(atPath: mmapReadyFile)
    try? FileManager.default.removeItem(atPath: mmapGoFile)
    try? FileManager.default.removeItem(atPath: mmapResultFile)
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    holder.arguments = ["mmaphold", mmapFile.path]
    if (try? holder.run()) != nil {
        try? "\(holder.processIdentifier)".write(toFile: mmapPidFile, atomically: true, encoding: .utf8)
        // 写像できたと言ってくるまで待つ（接続中なので即座のはず）。
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: mmapReadyFile), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        print(FileManager.default.fileExists(atPath: mmapReadyFile)
            ? "  mmap を張った常駐プロセスを起動しました（項目 12 用、pid \(holder.processIdentifier)）"
            : "  ★mmap 常駐プロセスが準備できませんでした（項目 12 は測れません）")
    }

    if let data = try? URL(fileURLWithPath: share).bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    {
        try? data.write(to: URL(fileURLWithPath: bookmarkFile))
        print("  ブックマークとプローブファイルを作成しました")
    } else {
        print("  ★ブックマークを作成できませんでした（NV-91 の項目は測れません）")
    }
    exit(0)

case "cleanup":
    // 常駐プロセスが残っていれば止める（フォルトで固まったままのことがある）。
    if let pidText = try? String(contentsOfFile: mmapPidFile, encoding: .utf8),
       let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0
    {
        kill(pid, SIGKILL)
        print("  mmap 常駐プロセスを停止しました（pid \(pid)）")
    }
    if let p = try? String(contentsOfFile: probeFileRecord, encoding: .utf8) {
        let dir = URL(fileURLWithPath: p).deletingLastPathComponent()
        // 共有では削除が一過性に失敗する（NV-104）。試し直す。
        //
        // **`fileExists` で成否を判定してはいけない。** SMB は dirent を
        // 最大 30 秒キャッシュするため、再接続直後は削除に失敗していても
        // 古い `false` が返る。実際にこの後片付けがそれを踏み、
        // 「削除しました」と報告しながら NAS にフォルダを残した。
        // `removeItem` が投げたエラーだけを信じる。
        // **遮断直後は共有が落ち着くまで時間がかかる。** 3 秒（10 回 × 0.3 秒）
        // では足りず、実際に 1 度消し損ねた。再接続直後だけの話なので、
        // ここは長めに取る（最大 15 秒）。
        var lastError: NSError?
        for attempt in 0..<30 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            do { try FileManager.default.removeItem(at: dir); lastError = nil; break }
            catch let error as NSError {
                if error.code == NSFileNoSuchFileError
                    || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                { lastError = nil; break }
                lastError = error
            }
        }
        if let lastError {
            print("  ★プローブフォルダを消せませんでした: \(dir.path) — \(lastError.localizedDescription)")
        } else {
            print("  プローブフォルダ: 削除しました")
        }
    }
    try? FileManager.default.removeItem(atPath: stateDir)
    exit(0)

case "mmaphold":
    // **遮断の前に**開いて写像し、そのまま待つ。`mmap-go` が現れたら
    // 全ページをフォルトさせ、結果を書いて終わる。フォルトが SIGBUS なら
    // ハンドラが痕跡を残してから死ぬ。
    let holdPath = share // 第 2 引数はファイルパス
    let holdFD = open(holdPath, O_RDONLY)
    guard holdFD >= 0 else { exit(2) }
    var holdStat = stat()
    fstat(holdFD, &holdStat)
    let holdSize = Int(holdStat.st_size)
    guard holdSize > 0,
          let holdBase = mmap(nil, holdSize, PROT_READ, MAP_PRIVATE, holdFD, 0),
          holdBase != MAP_FAILED
    else { exit(2) }
    close(holdFD)
    let holdBytes = holdBase.assumingMemoryBound(to: UInt8.self)
    // 接続中に 1 ページだけ触っておく（写像が生きていることの確認）。
    var warmup = Int(holdBytes[0])

    mmapResultFD = open(mmapResultFile, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    signal(SIGBUS) { _ in
        let message = "SIGBUS"
        _ = message.withCString { write(mmapResultFD, $0, strlen($0)) }
        _exit(9)
    }
    FileManager.default.createFile(atPath: mmapReadyFile, contents: Data("ready".utf8))

    // 遮断されるまで待つ。
    let holdDeadline = Date().addingTimeInterval(300)
    while !FileManager.default.fileExists(atPath: mmapGoFile), Date() < holdDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    // ここでフォルトさせる。ページは `purge` で追い出されているので、
    // 読みに行った先はネットワークになる。
    for off in stride(from: 0, to: holdSize, by: 4096) { warmup += Int(holdBytes[off]) }
    let text = "OK 全ページ読めた sum=\(warmup)（0x51 で書いたので、ゼロ埋めなら sum≒0）"
    _ = text.withCString { write(mmapResultFD, $0, strlen($0)) }
    exit(0)

case "mmapfault":
    // 子プロセスとして走る（SIGBUS で死んでも親の計測結果を巻き添えにしない）。
    // 第 2 引数はファイルパス。切断中の共有上のファイルを mmap し、全ページを
    // フォルトさせる。ローカル APFS の外部切り詰めは SIGBUS ではなくゼロ埋めに
    // なることを実測済み（2026-08 全体点検 F3）。ここで知りたいのは
    // 「フォルトがネットワーク I/O エラーになったとき」の挙動。
    let path = share
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { print("open 失敗 \(posixName(errno))"); exit(2) }
    var st = stat()
    fstat(fd, &st)
    let size = Int(st.st_size)
    guard size > 0, let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
        print("mmap 失敗 \(posixName(errno))"); exit(2)
    }
    close(fd)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0
    for off in stride(from: 0, to: size, by: 4096) { sum += Int(bytes[off]) }
    print("全ページ読めた sum=\(sum)（0x51 で書いたので、ゼロ埋めなら sum=0）")
    exit(0)

default:
    break
}

// MARK: - 遮断中の計測

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ label: String, _ text: String, _ started: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        lock.lock()
        lines.append(String(format: "  %-42@ %8.0fms  %@", label as NSString, ms, text as NSString))
        lock.unlock()
    }
    func dump() { lock.lock(); lines.sorted().forEach { print($0) }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
}

let results = Results()
let group = DispatchGroup()
var launched = 0

func measure(_ label: String, _ body: @escaping () -> String) {
    launched += 1
    group.enter()
    let thread = Thread {
        let started = DispatchTime.now()
        let text = body()
        results.add(label, text, started)
        group.leave()
    }
    thread.stackSize = 1 << 20
    thread.start()
}

let probeFile = (try? String(contentsOfFile: probeFileRecord, encoding: .utf8)) ?? "\(share)/none"

measure("01 stat（共有ルート）") {
    var i = stat(); errno = 0
    return stat(share, &i) == 0 ? "成功" : posixName(errno)
}
measure("02 contentsOfDirectory") {
    do { return "成功 \(try FileManager.default.contentsOfDirectory(atPath: share).count) 件" }
    catch {
        let e = error as NSError
        let u = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? -1
        return "失敗 \(e.domain)/\(e.code) posix=\(u >= 0 ? posixName(Int32(u)) : "なし")"
    }
}
measure("03 statfs（VolumeIdentity が使う）") {
    var i = statfs(); errno = 0
    return statfs(share, &i) == 0 ? "成功" : posixName(errno)
}
measure("04 access(W_OK)（NV-89 が使う）") {
    errno = 0
    return access(share, W_OK) == 0 ? "書ける" : posixName(errno)
}
measure("05 getmntinfo に載っているか（NV-93）") {
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { return "★取得できず" }
    for i in 0..<Int(count) {
        let path = withUnsafeBytes(of: buffer[i].f_mntonname) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if path == share { return "**載っている**（＝切断を退避の理由にしない）" }
    }
    return "**載っていない**"
}
measure("06 trashDirectory の問い合わせ") {
    do {
        _ = try FileManager.default.url(for: .trashDirectory, in: .allDomainsMask,
                                        appropriateFor: URL(fileURLWithPath: share), create: false)
        return "取得できた"
    } catch { return "失敗 \((error as NSError).code)" }
}
measure("07 FSEventStreamCreate + Start（NV-94）") {
    var context = FSEventStreamContext()
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
    guard let s = FSEventStreamCreate(kCFAllocatorDefault, { _, _, _, _, _, _ in }, &context,
                                      [share] as CFArray,
                                      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                      0.2, flags)
    else { return "★生成失敗" }
    FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "probe.fsev"))
    let ok = FSEventStreamStart(s)
    FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
    return ok ? "生成・開始とも成功（ブロックしない）" : "★開始に失敗"
}
measure("08 空き容量（VolumeCapacity）") {
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    guard let v = try? URL(fileURLWithPath: share).resourceValues(forKeys: keys) else { return "失敗" }
    return "important=\(v.volumeAvailableCapacityForImportantUsage.map(String.init) ?? "nil")"
        + " plain=\(v.volumeAvailableCapacity.map(String.init) ?? "nil")"
}
measure("09 ファイルを開いて読む") {
    errno = 0
    let fd = open(probeFile, O_RDONLY)
    if fd < 0 { return "open 失敗 \(posixName(errno))" }
    var buf = [UInt8](repeating: 0, count: 4096); errno = 0
    let n = read(fd, &buf, 4096); let e = errno; close(fd)
    return n >= 0 ? "読めた \(n) バイト" : "read 失敗 \(posixName(e))"
}
measure("10 ブックマーク解決（.withoutMounting, NV-91）") {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: bookmarkFile)) else { return "★準備なし" }
    var stale = false
    do {
        let u = try URL(resolvingBookmarkData: data, options: [.withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
        return "解決できた stale=\(stale) → \(u.lastPathComponent)"
    } catch { let e = error as NSError; return "失敗 \(e.domain)/\(e.code)" }
}
measure("11 新しいファイルを書く") {
    errno = 0
    let p = "\(share)/.qoo-write-\(UUID().uuidString)"
    let fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd < 0 { return "作成失敗 \(posixName(errno))" }
    close(fd); unlink(p); return "書けた"
}
measure("13 NSWorkspace.icon(forFile:)") {
    // `FileIconProvider` が `body` から同期的に呼ぶ。「Launch Services への
    // 問い合わせのみでファイル内容の読み取りを伴わない」は文献ベースの主張で、
    // 切断中にブロックしないかは未実測（2026-08 全体点検）。ブロックするなら
    // アイコン解決も `DisplayNameCache` と同じ非同期差し替え形へ変える必要がある。
    let icon = NSWorkspace.shared.icon(forFile: probeFile)
    return "返った（\(Int(icon.size.width))x\(Int(icon.size.height))）"
}
measure("14 getmntinfo(MNT_NOWAIT) — MountTable の前提") {
    // **`MountTable` はこれがブロックしないことに全面的に依存している。**
    // `DirectoryChangeHub` の「リモートか」の分類と、`WindowState` の
    // 「タブを退避してよいか」[NV-93] の両方がここを通る。しかも後者は
    // **切断されている最中にこそ呼ばれる**——ここでブロックすると、
    // 切断に耐えるために作った判定そのものがアプリを固めることになる。
    //
    // man page は `MNT_NOWAIT` を「ファイルシステムへ更新を要求せず、手元に
    // ある情報を返す」としているが、それは [文献] であって実測ではない。
    // 到達不能な共有がマウント表に載ったままの状態で確かめる。
    //
    // **`MNT_WAIT` と取り違えていないかもここで分かる** — そちらは各
    // ファイルシステムに `statfs` を要求するので、まず間違いなくブロックする。
    var buffer: UnsafeMutablePointer<statfs>?
    let started = DispatchTime.now()
    let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    guard count > 0, let buffer else { return "★取得できず" }
    defer { free(buffer) }
    // 遮断中の共有がまだ表に載っていること（＝ NV-93 の判定材料が残ること）も
    // 同時に確かめる。消えてしまうなら「未接続」ではなく「消えた」に見える。
    var stillListed = false
    for index in 0..<Int(count) {
        var entry = buffer[index]
        let mount = withUnsafeBytes(of: &entry.f_mntonname) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if mount == share { stillListed = true }
    }
    return String(format: "%d 件を %.3f ms で取得／遮断中の共有が表に載っている=%@",
                  count, elapsed, stillListed ? "はい" : "★いいえ")
}
measure("12 mmap ページのフォルト（F3: SIGBUS か）") {
    // **写像は遮断の前に張ってある**（`prepare` が常駐プロセスを起こす）。
    // ここでやるのは「フォルトしろ」と伝えて、生き死にを見届けることだけ。
    //
    // 最初の版はここで `open` していたが、遮断中なので ETIMEDOUT で終わり、
    // **知りたかった筋書き（写像済みのページが切断後にフォルトする）に
    // 一度も到達していなかった**。
    guard let pidText = try? String(contentsOfFile: mmapPidFile, encoding: .utf8),
          let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
          FileManager.default.fileExists(atPath: mmapReadyFile)
    else { return "★準備なし（常駐プロセスが起動していない）" }

    FileManager.default.createFile(atPath: mmapGoFile, contents: Data("go".utf8))

    let deadline = Date().addingTimeInterval(40)
    while Date() < deadline {
        if kill(pid, 0) != 0 { break }          // もう居ない
        if let r = try? String(contentsOfFile: mmapResultFile, encoding: .utf8), !r.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    let alive = kill(pid, 0) == 0
    let result = (try? String(contentsOfFile: mmapResultFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if result.hasPrefix("SIGBUS") {
        kill(pid, SIGKILL)
        return "★SIGBUS で死亡 — 切断中のフォルトは捕捉不能に落ちる。"
            + "ネットワーク上の PDF を CGPDFDocument に直接渡してはならない"
    }
    if alive && result.isEmpty {
        kill(pid, SIGKILL)
        return "★40 秒フォルトから返らず（ハング）— mmap 経路は期限もキャンセルも効かない"
    }
    if result.isEmpty {
        return "★プロセスが痕跡を残さず消えた（SIGBUS 以外のシグナルの可能性）"
    }
    return result
}

let waited = group.wait(timeout: .now() + .seconds(watchdogSeconds))
print("=== 遮断中の計測 ===")
results.dump()
if waited != .success {
    print("\n  ★ \(launched - results.count) 件が \(watchdogSeconds) 秒以内に返らなかった"
        + "（上の一覧に出ていないもの）。**それが最も重要な結果**である —"
        + " その操作はメインスレッドや協調プールで呼んではならない。")
} else {
    print("\n  全 \(launched) 件が \(watchdogSeconds) 秒以内に返った。")
}
exit(0)
