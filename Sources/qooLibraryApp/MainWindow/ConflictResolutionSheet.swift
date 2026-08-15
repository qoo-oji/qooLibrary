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
        // Esc やウインドウの都合で閉じられた場合の安全網。**継続を再開しない
        // まま終わると操作が止まったままになる**ため、閉じたら必ずスキップ
        // として解決する（`PermanentDeleteConfirmationSheet` と同じ方針）。
        .onDisappear { pending.resolve(.skip, applyToAll: false) }
    }

    @ViewBuilder
    private func fileSummary(titleKey: LocalizedStringKey, url: URL) -> some View {
        let info = Self.summary(of: url, locale: locale)
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            Text(titleKey)
                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Tokens.spacing.xs) {
                Image(nsImage: FileIconProvider.shared.icon(for: url))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.size)
                    Text(info.modified)
                }
                .font(.system(size: Tokens.fontSize.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func summary(of url: URL, locale: Locale) -> (size: String, modified: String) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let sizeFormatter = ByteCountFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let size = values?.isDirectory == true
            ? String(localized: "kind.folder", locale: locale)
            : sizeFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0))
        let modified = values?.contentModificationDate.map { dateFormatter.string(from: $0) } ?? "—"
        return (size, modified)
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
