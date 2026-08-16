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
    if let p = try? String(contentsOfFile: probeFileRecord, encoding: .utf8) {
        let dir = URL(fileURLWithPath: p).deletingLastPathComponent()
        // 共有では削除が一過性に失敗する（NV-104）。試し直す。
        for _ in 0..<10 where FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
            if FileManager.default.fileExists(atPath: dir.path) { Thread.sleep(forTimeInterval: 0.2) }
        }
        print("  プローブフォルダ: \(FileManager.default.fileExists(atPath: dir.path) ? "★残っている" : "削除しました")")
    }
    try? FileManager.default.removeItem(atPath: stateDir)
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
measure("12 mmap ページのフォルト（F3: SIGBUS か）") {
    // `CGPDFDocument(url:)` は後備ファイルを mmap する（lsof の txt 種別で
    // 実測確認済み）。切断中のフォルトが SIGBUS ならプロセスごと死ぬので、
    // 子プロセスで受けて終了状態から判定する。
    guard let mmapProbeFile = try? String(contentsOfFile: mmapFileRecord, encoding: .utf8) else {
        return "★準備なし"
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["mmapfault", mmapProbeFile]
    let out = Pipe()
    child.standardOutput = out
    do { try child.run() } catch { return "★子プロセスを起動できず" }
    let deadline = Date().addingTimeInterval(40)
    while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if child.isRunning {
        child.terminate()
        return "★40 秒返らず（フォルトでハング）— mmap 経路は期限もキャンセルも効かない"
    }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if child.terminationReason == .uncaughtSignal {
        return "★シグナルで死亡 signal=\(child.terminationStatus)（10=SIGBUS 11=SIGSEGV）"
            + " — CGPDFDocument をネットワーク上の PDF に直接使ってはならない"
    }
    return "子プロセス生存 exit=\(child.terminationStatus) \(text)"
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
