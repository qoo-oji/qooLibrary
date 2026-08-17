import Foundation
import QooKit

/// 一括転送の進み具合を数えて、間引きながら報告する [UI-09][A-04]。
///
/// ## 総量をいつ数えるか
/// 総バイト数を知るにはフォルダを再帰的に走査するしかなく、5 万件のライブラリ
/// では無視できない時間がかかる。一方で**同一ボリューム内のコピーはクローンで
/// 一瞬に終わる**（`FileCopyEngine` の実測表参照）ので、そこで数分かけて
/// サイズを数えるのは本末転倒になる。
///
/// そこで `volumeSupportsFileCloning` と移動元・移動先のボリュームを見て、
/// **「クローンで済むと分かっている場合は数えない」**。数えないときは
/// 件数だけを報告し、UI は不定進捗になる（が、そもそも一瞬で終わる）。
///
/// ## 間引き
/// `copyfile(3)` の status コールバックは 500MB のコピーで 400 回以上呼ばれる。
/// そのたびにメインアクタへ跳ぶと更新だけで忙しくなるため、`updateInterval`
/// より短い間隔の報告は捨てる（ただし項目の切り替わりと完了は必ず送る）。
/// ## なぜ参照型でロックを持つのか [NV6-01]
/// バイトを運ぶ本体（`copyfile(3)`）は `FileIO.perform` 経由で**協調プールの
/// 外**を走る。その status コールバックは**呼び出し元のスレッドで同期的に**
/// 呼ばれるので、進捗の受け口もそのスレッドから安全に触れなければならない。
///
/// `actor` にはできない——コールバックは同期であり `await` できない。
/// 値型のまま別スレッドへ渡すこともできない——`mutating` は共有できない。
/// **ロックで守った参照型**だけがこの制約を満たす。
///
/// ロックの中では `reporter.report(_:)` を呼ぶだけで、I/O も長い処理もしない。
final class ProgressTracker: @unchecked Sendable {
    /// 進捗を UI へ流す最短間隔。10 回/秒 あれば数字が滑らかに見える。
    private static let updateInterval: Duration = .milliseconds(100)

    private let lock = NSLock()
    private let reporter: ProgressReporter?
    private var progress: OperationProgress
    private var lastReportedAt: ContinuousClock.Instant?
    /// 今の項目で、バイトの報告を 1 度でも送ったか（leading edge の判定）。
    private var sentFirstBytesOfItem = false

    /// 実際に書き込まれるバイト数の見積もり。**空き容量の事前検査はこれを使う**
    /// [ER-03]。クローンで済む場合と、数えている途中で中断された場合は `nil`
    /// （＝検査しない。前者は 1 バイトも書かないので検査に意味が無く、後者は
    /// 過少な見積もりで誤って断らないため）。
    let requiredBytes: Int64?

    /// 走査中に見つけた、いちばん深い項目の相対パス。**パス長の事前検査
    /// [`FileOperationError.pathTooLong`] がこれを使う**。
    ///
    /// 専用の走査は増やさない — サイズを数えるためにどのみち全体を歩くので、
    /// そのついでに拾う。クローンで済む経路（走査しない）では `nil`。
    let deepestRelativePath: (path: String, item: URL)?

    /// 走査中に見つけた、いちばん大きいファイル。**ファイルサイズ上限の
    /// 事前検査 [`FileOperationError.fileTooLargeForDestination`] がこれを使う**。
    /// 深さと同じく、サイズを数えるついでに拾うので追加の走査は要らない。
    let largestFile: (size: Int64, item: URL)?

    /// 走査中に見つけた、いちばん長い**名前**（パスではなく 1 成分）。
    /// **名前の長さの事前検査 [`NameLengthLimit`] がこれを使う**。
    /// 深さ・大きさと同じく、走査のついでに拾う。
    let longestName: (name: String, item: URL)?

    /// - Parameter writesNoBytes: **1 バイトも書かないと分かっている操作**
    ///   （同一ボリューム内の移動 ＝ `rename(2)`）。`true` なら総量の走査も
    ///   行わない。`willBeInstant` はクローン対応と volumeUUID を要求するため
    ///   exFAT・SMB では偽になるが、移動はクローンの有無と無関係に
    ///   バイトを運ばない——ここを区別しないと、**空きの少ない exFAT/SMB
    ///   ボリューム内の正当な移動が「空き容量不足」で誤って断られる**
    ///   [フェーズ1完了時の監査で発見]。
    init(reporter: ProgressReporter?, items: [URL], destination: URL, writesNoBytes: Bool = false) {
        self.reporter = reporter
        if writesNoBytes || Self.willBeInstant(items: items, destination: destination) {
            requiredBytes = nil
            deepestRelativePath = nil
            largestFile = nil
            longestName = nil
        } else {
            // **報告先の有無に関わらず数える。** 以前は進捗表示が要らない
            // 呼び出しでは数えていなかったが、空き容量の事前検査もこの値を
            // 使うようになったため、進捗の都合で検査が抜けてはならない。
            // 走査するのはクローンできない経路だけで、その経路は元々
            // 実コピーの時間が支配的なので、走査の上乗せは相対的に小さい。
            let measured = Self.walk(items)
            requiredBytes = measured.bytes > 0 ? measured.bytes : nil
            deepestRelativePath = measured.deepest
            largestFile = measured.largest
            longestName = measured.longestName
        }
        let totalBytes = reporter == nil ? 0 : (requiredBytes ?? 0)
        self.progress = OperationProgress(totalBytes: totalBytes, totalItems: items.count)
    }

    func begin() { mutate(force: true, beginsItem: true) { _ in } }

    func startItem(_ item: URL) {
        mutate(force: true, beginsItem: true) { $0.currentItemName = item.lastPathComponent }
    }

    /// **別スレッドから呼ばれる。** `copyfile` の status コールバックは
    /// `FileIO.perform` が走らせているディスパッチスレッドの上にいる。
    ///
    /// **項目の最初のバイトは間引かない（leading edge）。** `startItem` が
    /// `lastReportedAt` を更新するため、素朴な間引きだと項目開始から
    /// `updateInterval` 以内のバイト報告はすべて捨てられる——速いディスクでは
    /// **1 項目のコピー全体がその窓に収まり、「コピーの最中」の報告が 1 度も
    /// 出ない**。CI（ページキャッシュに乗ったスパースイメージ）で実際に起き、
    /// 「最中を観測する」テスト（`PauseIntegrationTests`／
    /// `ReplaceBackupJournalTests`）が、最初に届く `completedBytes > 0` の報告
    /// ＝完了報告を「最中」と取り違えて落ちた。最初の 1 回を即時に送れば
    /// 「最初の報告の時点で残りは高々全体−1 チャンク」が速度によらず成立し、
    /// 進捗バーも即座に動き始める。
    func addBytes(_ bytes: Int64) {
        mutate(force: false) { $0.completedBytes += bytes }
    }

    func finishItem() {
        mutate(force: true) { $0.completedItems += 1 }
    }

    /// 更新と報告を 1 つのロックの下で行う。**報告する値をロックの中で
    /// 確定させてから外で渡す**——`reporter` の実装が何をするか分からないので、
    /// ロックを持ったまま呼ばない（呼び出し先がまたロックを取ると詰まる）。
    private func mutate(force: Bool, beginsItem: Bool = false, _ change: (inout OperationProgress) -> Void) {
        lock.lock()
        change(&progress)
        if beginsItem { sentFirstBytesOfItem = false }
        let now = ContinuousClock.now
        let shouldReport: Bool
        if force {
            shouldReport = true
        } else if !sentFirstBytesOfItem {
            shouldReport = true // 項目の最初のバイトは即時に送る（`addBytes` のコメント参照）
        } else if let last = lastReportedAt, now - last < Self.updateInterval {
            shouldReport = false
        } else {
            shouldReport = true
        }
        if shouldReport {
            lastReportedAt = now
            if !force { sentFirstBytesOfItem = true }
        }
        let snapshot = progress
        lock.unlock()

        guard shouldReport, let reporter else { return }
        reporter.report(snapshot)
    }

    // MARK: - 事前の見積もり

    /// クローンで済む（＝バイトを運ばない）と分かるか。
    ///
    /// 同一ボリュームであることに加えて **`volumeSupportsFileCloning` まで
    /// 見る**。同じボリュームでも exFAT の USB メモリのようにクローンできない
    /// ファイルシステムがあり、そこでは実際に時間がかかるため進捗が要る。
    private static func willBeInstant(items: [URL], destination: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeSupportsFileCloningKey]
        guard let destinationValues = try? destination.resourceValues(forKeys: keys),
              destinationValues.volumeSupportsFileCloning == true,
              let destinationVolume = destinationValues.volumeUUIDString
        else { return false }
        return items.allSatisfy { item in
            (try? item.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == destinationVolume
        }
    }

    /// 対象を 1 度だけ歩いて、合計バイト数と「いちばん深い相対パス」の
    /// 両方を拾う。**同じ木を 2 度歩かないため 1 つにまとめてある**
    /// （5 万件のライブラリでは走査自体が無視できない）。
    ///
    /// 中断されたら数えるのをやめて 0 を返す（＝不定進捗になる）。数えている
    /// 最中にキャンセルされた場合、そこで待たせ続ける方が害が大きい。
    private static func walk(
        _ items: [URL]
    ) -> (
        bytes: Int64,
        deepest: (path: String, item: URL)?,
        largest: (size: Int64, item: URL)?,
        longestName: (name: String, item: URL)?
    ) {
        var total: Int64 = 0
        var deepest: (path: String, item: URL)?
        var largest: (size: Int64, item: URL)?
        var longestName: (name: String, item: URL)?
        func noteName(_ item: URL) {
            let name = item.lastPathComponent
            // どの単位で数えるかは書き込み先次第なので、ここでは素の
            // バイト数がいちばん大きいものを候補にしておく（バイト単位の
            // 形式でこそ問題になるため）。
            if name.utf8.count > (longestName?.name.utf8.count ?? -1) {
                longestName = (name, item)
            }
        }
        func noteSize(_ size: Int64, _ item: URL) {
            if size > (largest?.size ?? -1) { largest = (size, item) }
        }
        func note(_ relativePath: String, _ item: URL) {
            if relativePath.utf8.count > (deepest?.path.utf8.count ?? -1) {
                deepest = (relativePath, item)
            }
        }
        for item in items {
            if Cancellation.isRequested { return (0, nil, nil, nil) }
            let name = item.lastPathComponent
            note(name, item)
            noteName(item)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue } // リンク自体は運ぶだけ [SL-01]
            if values?.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(
                    at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
                ) else { continue }
                let rootPath = item.standardizedFileURL.path
                while let child = enumerator.nextObject() as? URL {
                    if Cancellation.isRequested { return (0, nil, nil, nil) }
                    noteName(child)
                    // 運んだあとの相対パスは「項目名 + 起点からの相対パス」。
                    // `NSDirectoryEnumerator` は相対パスを公開していないので
                    // 起点のパスを前から削って求める。
                    let childPath = child.standardizedFileURL.path
                    if childPath.hasPrefix(rootPath + "/") {
                        note(name + "/" + String(childPath.dropFirst(rootPath.count + 1)), child)
                    }
                    let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard childValues?.isRegularFile == true else { continue }
                    let size = Int64(childValues?.fileSize ?? 0)
                    total += size
                    noteSize(size, child)
                }
            } else {
                let size = Int64(values?.fileSize ?? 0)
                total += size
                noteSize(size, item)
            }
        }
        return (total, deepest, largest, longestName)
    }
}
