import QooKit
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
struct StatusBarView<Trailing: View>: View {
    @Environment(\.locale) private var locale
    let folder: URL?
    let itemCount: Int
    let selectedCount: Int
    /// `SessionState.reloadToken`。ファイル操作のたびに空き容量を取り直すための
    /// トリガ（値自体は使わない）。
    let reloadToken: Int
    /// 再帰検索の状態 [ユーザー要望]。走査中であること・上限で打ち切ったことを
    /// 件数の隣に添える（一覧が「全部」ではないと分かるようにするため）。
    var isSearching = false
    var searchTruncated = false
    /// 隠しファイルを表示するか [ユーザー要望、Finder の ⇧⌘. 相当]。
    /// **左端**のボタンで切り替える。
    @Binding var showHiddenFiles: Bool
    /// **右端**に置く表示オプション（リスト表示なら表示カラムのメニュー、
    /// アイコン表示ならサイズのスライダー）[ユーザー要望でパスバーから移動]。
    /// 実体は `FolderContentView` 側にある（設定値をそこが持っているため）
    /// ので、組み立て済みのビューを受け取るだけにしている。
    @ViewBuilder let trailing: () -> Trailing

    @State private var availableCapacity: Int64?

    var body: some View {
        // **件数はバーの中央に固定する**（Finder と同じ）。左右のコントロールと
        // 同じ `HStack` に並べると、コントロールの幅で中央がずれてしまうため、
        // 中央のテキストと左右のコントロールを `ZStack` で重ねる。
        ZStack {
            Text(summary)
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)

            HStack(spacing: Tokens.spacing.s) {
                Toggle(isOn: $showHiddenFiles) {
                    Image(systemName: showHiddenFiles ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(showHiddenFiles ? "statusBar.hideHiddenFiles" : "statusBar.showHiddenFiles")

                Spacer()

                trailing()
            }
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
        if isSearching {
            parts.append(String(localized: "statusBar.searching", locale: locale))
        } else if searchTruncated {
            parts.append(String(
                format: String(localized: "statusBar.searchTruncated", locale: locale),
                AppLimits.Search.maxResults
            ))
        }
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
