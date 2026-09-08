#if DEBUG
import AppKit
import Darwin
import Foundation
import QooInfrastructure

/// デバッグビルド限定の制御口 [MT-33]。GUI を 1 度も操作せずに、実際に走って
/// いるアプリの状態を読み、操作を起こすための唯一の入口。
///
/// **なぜ必要か**: 実機検証は GUI の自動操作（合成イベント）に頼っており、
/// ①利用者の画面を数十分奪う ②人が同じマシンを触ると前提が崩れ、崩れ方が
/// 実装の欠陥とまったく同じ形で現れる ③道具が毎回作り直しになる、という
/// 3 つの費用を払っていた。この口は本物のプロセス・本物のサンドボックス・
/// 本物の DB・本物のメニューバー配線を保ったまま、そのどれも払わずに済ませる。
///
/// **二重の関門**: `#if DEBUG` でリリースビルドからは丸ごと消え、さらに起動
/// 引数 `--qoo-control` が無ければ socket を 1 つも開かない。既定では
/// アプリのコンテナ内にしか作らないので、他のプロセスから覗くには同じ
/// ユーザーの権限が要る（作成時に 0600 を明示する）。
///
/// **プロトコル**: 1 接続につき 1 往復。改行で終わる JSON オブジェクトを送ると、
/// 改行で終わる JSON オブジェクトが返る。`{"cmd": "...", "args": {...}}` →
/// `{"ok": true, "result": {...}}` または `{"ok": false, "error": "..."}`。
/// シェル・Python・Swift のどれからでも 3 行で叩ける形にしてある。
public enum ControlServer {
    /// 起動引数にこれがあるときだけ口を開く。
    static let enableFlag = "--qoo-control"
    /// これがあるとウインドウを 1 枚も開かずに起動する（`.suppressed`）。
    static let headlessFlag = "--qoo-headless"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(enableFlag)
    }

    /// ウインドウを開かずに起動するか。**口が要求されているときだけ効く** —
    /// 通常の起動でウインドウが出ないのは事故なので、単独では成立させない。
    public static var isHeadless: Bool {
        isRequested && ProcessInfo.processInfo.arguments.contains(headlessFlag)
    }

    /// socket の置き場所。**パスは固定** — `sockaddr_un.sun_path` は 104 バイト
    /// しかなく、外から任意のパスを受けると溢れうる。加えてサンドボックス下では
    /// どのみちコンテナの外に bind できないので、選ばせる理由が無い。
    static var socketPath: String {
        NSHomeDirectory() + "/qoo-control.sock"
    }

    private enum BindOutcome {
        case opened(Int32)
        case refused(String)
    }

    private nonisolated(unsafe) static var listenFD: Int32 = -1

    /// 口を開く。要求されていなければ何もしない。
    ///
    /// 失敗しても投げない — 検証の道具がアプリの起動を妨げてはならない。
    /// 理由は診断ログへ残す。
    public static func startIfRequested() {
        guard isRequested else { return }
        switch bind(at: socketPath) {
        case .opened(let fd):
            listenFD = fd
            Thread.detachNewThread { acceptLoop(fd) }
            Log.ui.info("制御口を開きました [MT-33]: \(Log.path(URL(fileURLWithPath: socketPath)))")
        case .refused(let reason):
            Log.ui.error("制御口を開けませんでした [MT-33]: \(reason)")
        }
    }

    private static func bind(at path: String) -> BindOutcome {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refused("socket() errno=\(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            return .refused("パスが長すぎます（\(bytes.count) >= \(capacity)）: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { slot in
                for (i, byte) in bytes.enumerated() { slot[i] = CChar(bitPattern: byte) }
                slot[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            return .refused("bind() errno=\(errno)")
        }
        // 同じユーザーの他プロセスからしか繋げないようにする。
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            return .refused("listen() errno=\(errno)")
        }
        return .opened(fd)
    }

    private static func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handle(client)
            close(client)
        }
    }

    private static func handle(_ client: Int32) {
        guard let line = readLine(from: client) else {
            write(reply: ControlResponse.failure("リクエストを読めませんでした"), to: client)
            return
        }
        let response = ControlDispatcher.dispatchOnMain(line)
        write(reply: response, to: client)
    }

    private static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return data.isEmpty ? nil : data
    }

    private static func write(reply: Data, to fd: Int32) {
        var payload = reply
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}

/// 応答の組み立て。すべてのコマンドがこの形で返す。
enum ControlResponse {
    static func success(_ result: [String: Any]) -> Data {
        encode(["ok": true, "result": result])
    }

    static func failure(_ message: String) -> Data {
        encode(["ok": false, "error": message])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"応答を JSON にできませんでした"}"#.utf8)
    }
}
#endif
