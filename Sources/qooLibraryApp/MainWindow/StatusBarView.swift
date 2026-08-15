import SwiftUI

/// 中央ペイン下端のステータスバー [1-16 表示メニュー、Finder の「ステータス
/// バーを表示」（⌘/）相当]。項目数・選択件数・そのボリュームの空き容量を出す。
///
/// **件数は `FolderContentView` が既に読み込み済みの `entries` から数えるだけ**
/// [設計判断]。`InspectorPane` が持つ再帰的な集計（DT-05/DT-06、配下すべての
/// ファイル数・合計サイズ）とは別物で、こちらは現在のフォルダの直下だけを見る
/// —— Finder のステータスバーも同じで、常時表示されるものに再帰走査のコストを
/// 持ち込まないためでもある。
///
/// 空き容量だけは問い合わせが要るが、`URLResourceValues` の 1 回の取得で済む。
/// 頻繁に変わる値ではないので、フォルダが変わったときと一覧が再読み込みされた
/// ときにだけ取り直す。
struct StatusBarView: View {
    @Environment(\.locale) private var locale
    let folder: URL?
    let itemCount: Int
    let selectedCount: Int
    /// `SessionState.reloadToken`。ファイル操作のたびに空き容量を取り直すための
    /// トリガ（値自体は使わない）。
    let reloadToken: Int

    @State private var availableCapacity: Int64?

    var body: some View {
        HStack(spacing: Tokens.spacing.s) {
            Spacer()
            Text(summary)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.xs)
        .background(.thinMaterial)
        .task(id: TaskKey(folder: folder, reloadToken: reloadToken)) {
            availableCapacity = await Self.availableCapacity(of: folder)
        }
    }

    /// Finder のステータスバーと同じ体裁: 「N 項目、M 項目を選択、X GB 空き」。
    /// 選択が無いときは選択の節を出さない。空き容量が取れないボリューム
    /// （ネットワーク等）では容量の節を落とす。
    private var summary: String {
        var parts: [String] = []
        parts.append(String(format: String(localized: "statusBar.itemCount", locale: locale), itemCount))
        if selectedCount > 0 {
            parts.append(String(format: String(localized: "statusBar.selectedCount", locale: locale), selectedCount))
        }
        if let availableCapacity {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let formatted = formatter.string(fromByteCount: availableCapacity)
            parts.append(String(format: String(localized: "statusBar.available", locale: locale), formatted))
        }
        return parts.joined(separator: String(localized: "statusBar.separator", locale: locale))
    }

    /// `.task(id:)` は 1 つの値しか取れないため、フォルダと再読み込み信号を束ねる。
    private struct TaskKey: Equatable {
        let folder: URL?
        let reloadToken: Int
    }

    /// **`volumeAvailableCapacityForImportantUsageKey` を使う** [設計判断]。
    /// 素の `volumeAvailableCapacityKey` は purgeable（削除可能なキャッシュ等）を
    /// 差し引いた保守的な値で、Finder が表示する「空き」より小さく出るため、
    /// Finder に並べて使うアプリとして数字が食い違って見える。
    private static func availableCapacity(of folder: URL?) async -> Int64? {
        guard let folder else { return nil }
        return await Task.detached {
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }.value
    }
}
