import Observation
import QooKit
import SwiftUI

/// 実行中の長時間処理を集める、アプリ全体で 1 つの受け皿 [UI-09][A-04]。
///
/// **なぜアプリ全体で 1 つなのか**［ユーザー要望: 進捗はウインドウ上の
/// オーバーレイではなく別の小さなウインドウにしたい］: `FolderOperations` は
/// ペインごと（中央ペインとフォルダツリーで別インスタンス）に存在するので、
/// そのまま窓を出すと同じ操作の窓が二重に出たり、ウインドウごとにばらばらの
/// 窓が並んだりする。Finder も進捗はアプリに 1 つの窓へ集約し、同時に走る
/// 操作を行として並べる。それに倣う。
@MainActor
@Observable
final class OperationProgressCenter {
    static let shared = OperationProgressCenter()

    private(set) var operations: [ActiveOperation] = []

    /// 処理が増減したときだけ呼ばれる（進捗の更新では呼ばれない）。
    /// 窓の出し入れを担う `OperationProgressWindowController` が設定する。
    ///
    /// **`withObservationTracking` ではなく明示的な呼び出しにしている**
    /// [設計判断]。`withObservationTracking` の通知は 1 回きりで、
    /// `onChange` の中から張り直すまでの間に起きた変更は観測できない
    /// （Swift の Observation の仕様）。進捗は毎秒 10 回ほど更新される一方、
    /// 窓の出し入れに必要なのは増減だけなので、更新頻度に影響されない
    /// この形の方が素直で確実。
    ///
    /// - Note: 窓が閉じずに残る不具合を実際に 1 件踏んでいるが、その原因は
    ///   観測ではなく `FolderOperations.run()` の後始末の順序だった
    ///   （エラーダイアログが閉じられるまで `finish()` に到達しなかった）。
    @ObservationIgnored
    var onActivityChanged: (@MainActor () -> Void)?

    private init() {}

    var isEmpty: Bool { operations.isEmpty }

    /// 処理の開始を登録し、以後その処理を指す handle を返す。
    func begin(
        title: String,
        cancel: (@MainActor () -> Void)? = nil,
        pauseToken: PauseToken? = nil
    ) -> Handle {
        let operation = ActiveOperation(title: title, cancel: cancel, pauseToken: pauseToken)
        operations.append(operation)
        onActivityChanged?()
        return Handle(id: operation.id)
    }

    func update(_ handle: Handle, progress: OperationProgress?, detail: String?) {
        guard let index = operations.firstIndex(where: { $0.id == handle.id }) else { return }
        operations[index].progress = progress
        operations[index].detail = detail
        // 速度の基準は「バイトが実際に動き始めた時点」。**開始時刻を基準に
        // してはいけない** — 転送の前に合計サイズを数える時間（項目数が多いと
        // 数秒かかる）が入り、速度を大幅に低く＝残り時間を過大に見積もる。
        if let progress, progress.completedBytes > 0, operations[index].speedOrigin == nil {
            operations[index].speedOrigin = SpeedOrigin(at: .now, bytes: progress.completedBytes)
        }
    }

    func finish(_ handle: Handle) {
        operations.removeAll { $0.id == handle.id }
        onActivityChanged?()
    }

    func cancel(_ id: UUID) {
        operations.first { $0.id == id }?.cancel?()
    }

    /// 一時停止／再開を切り替える [ユーザー要望]。
    func togglePause(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              let token = operations[index].pauseToken else { return }
        operations[index].isPaused = token.toggle()
        // 再開したら速度の基準を取り直す。止まっていた時間をそのまま平均に
        // 入れると、残り時間が実際よりずっと長く出てしまうため。
        if !operations[index].isPaused { operations[index].speedOrigin = nil }
    }

    /// 登録した処理を指す控え。`FolderOperations` はこれだけを持ち回る。
    struct Handle: Sendable {
        let id: UUID
    }

    struct ActiveOperation: Identifiable {
        let id = UUID()
        /// 「コピーしています…」など、何をしているか。
        let title: String
        /// 「3/12 件 — 1.2 GB / 8.4 GB」など。総量が分かる前は `nil`。
        var detail: String?
        var progress: OperationProgress?
        /// 中断手段。無い処理（中断できないもの）では `nil` にし、
        /// ボタン自体を出さない。
        let cancel: (@MainActor () -> Void)?
        /// 一時停止手段。`nil` ならボタンを出さない。
        let pauseToken: PauseToken?
        /// 表示用の控え（`PauseToken` は `@Observable` ではないため、画面の
        /// 描き直しはこちらの値の変化で起こす）。
        var isPaused = false
        /// 残り時間を出すための速度の基準点（`update` が最初の実バイトで置く）。
        var speedOrigin: SpeedOrigin?

        /// 0.0〜1.0。総量が不明なら `nil`（不定進捗として描く）。
        var fraction: Double? { progress?.fraction }

        /// 推定残り時間 [ユーザー要望]。基準点からの平均速度で見積もる。
        ///
        /// 直近の瞬間速度ではなく**平均**を使う [設計判断]: 瞬間速度は
        /// ファイルの切り替わりやディスクのバースト書き込みで大きく振れ、
        /// 表示が「3 秒 → 2 分 → 10 秒」と暴れて役に立たない。平均は
        /// 落ち着いて単調に減る。
        ///
        /// 出さない条件（**当てにならない数字を出さない方がまし**）:
        /// - 総バイト数が分からない（クローンで一瞬に終わる転送、圧縮・展開）
        /// - 計測開始から 1 秒未満（最初の 1 サンプルは極端に外れる）
        /// - 残りが無い（完了間際）
        var estimatedRemaining: Duration? {
            // 止まっている間は「あと何秒」に意味が無い。
            guard !isPaused else { return nil }
            guard let progress, progress.totalBytes > 0, let origin = speedOrigin else { return nil }
            let elapsed = ContinuousClock.now - origin.at
            let moved = progress.completedBytes - origin.bytes
            guard elapsed > .seconds(1), moved > 0 else { return nil }
            let remaining = progress.totalBytes - progress.completedBytes
            guard remaining > 0 else { return nil }
            let bytesPerSecond = Double(moved) / elapsed.inSeconds
            guard bytesPerSecond > 0 else { return nil }
            return .seconds(Double(remaining) / bytesPerSecond)
        }
    }

    struct SpeedOrigin {
        let at: ContinuousClock.Instant
        let bytes: Int64
    }
}

private extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// 進捗ウインドウの中身。行が 1 つでも複数でも同じ見た目になるよう、
/// 常に一覧として描く。
struct OperationProgressWindowContent: View {
    @Environment(\.locale) private var locale
    var center = OperationProgressCenter.shared

    /// ボタン内の文字が占める最小幅［ユーザー要望: 「一時停止」と「再開」で
    /// 幅を変えない、キャンセルと同じ幅でよい］。文字数の違いでボタンが
    /// 伸び縮みすると、押そうとした位置がずれる。**固定幅ではなく下限**に
    /// してあるのは、英語やより長い訳語でも文字が切れないようにするため。
    /// 下限は 3 つのラベルの実測幅の max — 以前は固定 56pt で、`.small` の
    /// 「キャンセル」がわずかに超えて完全には揃っていなかった。
    private var buttonLabelWidth: CGFloat {
        DialogButtonMetrics.maxLabelWidth(
            [
                String(localized: "progress.pause", locale: locale),
                String(localized: "progress.resume", locale: locale),
                String(localized: "common.cancel", locale: locale),
            ],
            controlSize: .small
        )
    }

    /// 「12 件中 3 件目（残り 9 件） — 1.49 GB / 4.29 GB — 残り約 2 分」。
    /// 件数・バイト数は処理側が組み立てた `detail` をそのまま使い、
    /// 残り時間だけはここで時刻を読んで足す（表示のたびに計算し直す）。
    private func detailText(for operation: OperationProgressCenter.ActiveOperation) -> String? {
        var parts: [String] = []
        if operation.isPaused { parts.append(String(localized: "progress.paused", locale: locale)) }
        if let detail = operation.detail { parts.append(detail) }
        if let remaining = operation.estimatedRemaining, let text = Self.durationText(remaining, locale: locale) {
            parts.append(String(format: String(localized: "progress.remaining", locale: locale), text))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// 「2 分 30 秒」。`maximumUnitCount` を 2 にして「1 時間 3 分 12 秒」の
    /// ような読みにくい表示を避ける。1 秒未満は「1 秒未満」に丸める
    /// （`DateComponentsFormatter` は 0 秒に対して空文字を返すため）。
    private static func durationText(_ duration: Duration, locale: Locale) -> String? {
        let seconds = max(1.0, Double(duration.components.seconds))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            ForEach(center.operations) { operation in
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(operation.title)
                        .font(.system(size: Tokens.fontSize.body))
                    // **今どのファイルを処理しているか**［ユーザー要望］。
                    // 名前は長くなりがちなので中央を省略する（末尾の省略だと
                    // 拡張子や巻数が消えて、どのファイルか分からなくなる）。
                    if let name = operation.progress?.currentItemName {
                        Text(name)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let fraction = operation.fraction {
                        ProgressView(value: fraction)
                    } else {
                        // 総量が分からない処理（クローンで一瞬に終わるコピー、
                        // 圧縮・展開など）は不定進捗。
                        ProgressView().progressViewStyle(.linear)
                    }
                    // 状況（件数・残り件数・バイト数・残り時間）は**1 行に収める**
                    //［ユーザー指摘: 途中で折り返さないでほしい］。中断ボタンと
                    // 同じ行に置くと横幅を奪われて折り返すため、ボタンは
                    // さらに下の行へ独立させた。長い文言（「残り約 1 時間 20 分」
                    // 等）でも折り返さないよう、収まらないときは少しだけ縮める。
                    if let detail = detailText(for: operation) {
                        Text(detail)
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // **ボタンはバーの下**［ユーザー指摘: 進捗バーの上に置くのは
                    // 一般的ではない］。macOS のダイアログと同じく右下に置き、
                    // 一時停止は中断の左［ユーザー要望］。
                    HStack {
                        Spacer()
                        if operation.pauseToken != nil {
                            Button { center.togglePause(operation.id) } label: {
                                // **幅はラベル側で確保する**。`Button` の外側に
                                // `.frame` を付けても、枠が広がるだけでボタンの
                                // 見た目（カプセル）は元の大きさのままになる
                                // （実機で「再開」だけ細いままだった）。
                                Text(operation.isPaused ? "progress.resume" : "progress.pause")
                                    .frame(minWidth: buttonLabelWidth)
                            }
                            .controlSize(.small)
                        }
                        if let cancel = operation.cancel {
                            Button(role: .cancel) { cancel() } label: {
                                Text("common.cancel").frame(minWidth: buttonLabelWidth)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if operation.id != center.operations.last?.id { Divider() }
            }
        }
        .padding(Tokens.spacing.l)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
