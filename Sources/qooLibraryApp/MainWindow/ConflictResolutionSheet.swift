import QooInfrastructure
import QooKit
import SwiftUI

/// 同名の項目が既にある場合にどうするかを尋ねる [FM-11][FM-12]。
///
/// Finder と同じ 3 択（置き換える／両方とも残す／スキップ）に加えて、
/// 「以降すべてに適用」を出す [FM-12]。判断の材料になるよう、**両方の
/// 大きさと更新日を並べて見せる** — 「新しい方で上書きしたい」かどうかは
/// それが分からないと決められない。
struct ConflictResolutionSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let pending: PendingConflict
    /// このシートを閉じる（＝保留状態を消す）ための後片付け。**閉じないと
    /// 次の衝突のシートが出せず、2 秒の見張りに拾われて黙ってスキップされる**
    /// [レビューで発見]。
    let onFinish: () -> Void
    @State private var applyToAll = false

    /// パスごとの、表示用に整えた要約。
    ///
    /// **ビューの中でボリュームへ問い合わせてはならない** [NV6-02]。
    /// このシートが出るのは「コピー先に同じ名前がある」ときで、その相手は
    /// ネットワーク上のこともある。`body` の中で `resourceValues` を読むと
    /// **メインスレッドがそのまま止まる**うえ、`body` は「以降すべてに適用」を
    /// 切り替えるたびに評価し直されるので、**問い合わせが何度も繰り返される**。
    @State private var summaries: [String: FileSummary] = [:]

    /// 表示用に整えた 1 件分。
    private struct FileSummary: Sendable {
        var size: String
        var modified: String
    }

    /// ボリュームから読んだままの 1 件分。整形はメインアクタ側で行う
    /// （`DateFormatter` に `locale` を渡す必要があるため）。
    private struct RawFileInfo: Sendable {
        var isDirectory: Bool
        var fileSize: Int
        var modified: Date?
    }

    private func resolve(_ policy: ConflictPolicy) {
        pending.resolve(policy, applyToAll: applyToAll)
        onFinish()
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text("conflict.title")
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))
            Text(String(format: String(localized: "conflict.message", locale: locale), pending.destination.lastPathComponent))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Tokens.spacing.l) {
                fileSummary(titleKey: "conflict.existingItem", url: pending.destination)
                Divider()
                fileSummary(titleKey: "conflict.replacementItem", url: pending.source)
            }
            .padding(Tokens.spacing.s)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))

            // [FM-12] 残りの項目にも同じ判断を使う。1 件しか衝突していない
            // 場合でも出す — このダイアログを開いた時点では、あと何件
            // 衝突するかがまだ分かっていないため。
            Toggle("conflict.applyToAll", isOn: $applyToAll)

            HStack {
                Button("conflict.skip") { resolve(.skip) }
                Spacer()
                Button("conflict.keepBoth") { resolve(.keepBoth) }
                Button("conflict.replace") { resolve(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.spacing.l)
        .frame(width: 520)
        .onAppear { pending.didAppear = true }
        // **`id:` を必ず付ける。** 一括処理では衝突が連続して起こり、
        // SwiftUI がシートの中身のビュー同一性を使い回すことがある。
        // 素の `.task` はビュー同一性に結び付くので、そのとき再実行されず、
        // **前の衝突のパスで引いた要約が残って両方「—」になる**——
        // 判断材料がゼロのまま置き換えを選ばせることになる。
        .task(id: pending.id) { await loadSummaries() }
        // Esc やウインドウの都合で閉じられた場合の安全網。**継続を再開しない
        // まま終わると操作が止まったままになる**ため、閉じたら必ずスキップ
        // として解決する（`PermanentDeleteConfirmationSheet` と同じ方針）。
        .onDisappear { pending.resolve(.skip, applyToAll: false) }
    }

    /// 両方の要約をまとめて 1 回で読む。
    ///
    /// 2 件を別々に読むと往復が 2 回になるので、`FileIO` へは 1 回だけ渡す
    /// （[NV-98] の「問い合わせは操作ごとに 1 回」と同じ考え方）。
    private func loadSummaries() async {
        let urls = [pending.destination, pending.source]
        let raw = await FileIO.perform {
            var result: [String: RawFileInfo] = [:]
            for url in urls {
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
                )
                result[url.path] = RawFileInfo(
                    isDirectory: values?.isDirectory ?? false,
                    fileSize: values?.fileSize ?? 0,
                    modified: values?.contentModificationDate
                )
            }
            return result
        }
        summaries = raw.mapValues { format($0) }
    }

    private func format(_ info: RawFileInfo) -> FileSummary {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let size = info.isDirectory
            ? String(localized: "kind.folder", locale: locale)
            : ByteCountFormatter().string(fromByteCount: Int64(info.fileSize))
        return FileSummary(
            size: size,
            modified: info.modified.map { dateFormatter.string(from: $0) } ?? "—"
        )
    }

    @ViewBuilder
    private func fileSummary(titleKey: LocalizedStringKey, url: URL) -> some View {
        // 読めるまでは「—」を出す。**待たせない**のがここでの正しさで、
        // ネットワーク越しなら埋まるまでに一瞬かかることがある。
        let info = summaries[url.path]
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text(titleKey)
                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Tokens.spacing.xs) {
                Image(nsImage: FileIconProvider.shared.icon(for: url))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info?.size ?? "—")
                    Text(info?.modified ?? "—")
                }
                .font(.system(size: Tokens.fontSize.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// 衝突 1 件ぶんの保留状態 [`PendingLockedItem` と同じ形]。
///
/// **継続は必ず 1 回だけ再開する** — 2 回再開するとクラッシュし、0 回だと
/// 操作が永久に返らない。`resolve` が最初の 1 回だけ通す。
@MainActor
final class PendingConflict: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
    /// シートが実際に表示されたか。表示されないまま終わった場合の保険が、
    /// ユーザーの長考と取り違えないようにするための印
    /// [`PendingLockedItem.didAppear` と同じ理由]。
    var didAppear = false
    private var callback: ((ConflictPolicy, Bool) -> Void)?

    init(source: URL, destination: URL, onResolve: @escaping (ConflictPolicy, Bool) -> Void) {
        self.source = source
        self.destination = destination
        self.callback = onResolve
    }

    /// - Parameter applyToAll: 「以降すべてに適用」[FM-12]
    func resolve(_ policy: ConflictPolicy, applyToAll: Bool) {
        guard let callback else { return }
        self.callback = nil
        callback(policy, applyToAll)
    }
}
