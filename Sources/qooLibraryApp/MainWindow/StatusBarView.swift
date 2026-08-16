import QooInfrastructure
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
    /// 表示中のフォルダに変更があった回数
    /// [`DirectoryObservation.generation`]。空き容量を取り直すためのトリガで、
    /// 値自体は使わない。
    let refreshToken: Int
    /// 再帰検索の状態 [ユーザー要望]。走査中であること・上限で打ち切ったことを
    /// 件数の隣に添える（一覧が「全部」ではないと分かるようにするため）。
    var isSearching = false
    var searchTruncated = false
    /// 隠しファイルを表示するか [ユーザー要望、Finder の ⇧⌘. 相当]。
    /// **左端**のボタンで切り替える。
    @Binding var showHiddenFiles: Bool
    /// サムネイルが隠れている理由。隠れていなければ `nil` [DS-07]。
    /// 隠しファイルのボタンの隣に、同じ体裁のトグルとして常設する。
    let thumbnailHiddenReason: ThumbnailHiddenReason?
    /// アプリ全体のトグルを反転する [DS-01][DS-02]。
    let onToggleThumbnails: () -> Void
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

                thumbnailToggle

                Spacer()

                trailing()
            }
        }
        .padding(.horizontal, Tokens.spacing.m)
        .padding(.vertical, Tokens.spacing.xs)
        .background(.thinMaterial)
        .task(id: TaskKey(folder: folder, refreshToken: refreshToken)) {
            availableCapacity = await Self.availableCapacity(of: folder)
        }
    }

    /// サムネイル表示の状態表示と切り替え [DS-07][DS-01][DS-02]。
    ///
    /// 隠しファイルのボタンと同じ「状態を絵で示す＋押して切り替える」体裁に
    /// 揃え、**非表示のときだけ強調される**（`isOn` に非表示を渡している）。
    /// 通常の状態を強調しないほうが、目立つのは異常時だけになって読みやすい
    /// ——隠しファイル側も「表示している間だけ強調される」で同じ考え方。
    ///
    /// **ライブラリ側の強制非表示 [DS-04] のときは押せない。** そのとき全体
    /// トグルを反転しても見た目は変わらないため、押せてしまうほうが不親切に
    /// なる。代わりにツールチップで理由と直し方を案内する [DS-07]。
    @ViewBuilder
    private var thumbnailToggle: some View {
        let isHidden = thumbnailHiddenReason != nil
        let isLockedByFolder: Bool = if case .registeredFolder = thumbnailHiddenReason { true } else { false }

        Toggle(isOn: Binding(get: { isHidden }, set: { _ in onToggleThumbnails() })) {
            Image(systemName: isHidden ? "photo.badge.exclamationmark" : "photo")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isLockedByFolder)
        .help(thumbnailHelp)
    }

    private var thumbnailHelp: String {
        switch thumbnailHiddenReason {
        case .registeredFolder(let displayName):
            String(
                format: String(localized: "statusBar.thumbnailsHiddenByFolder", locale: locale),
                displayName
            )
        case .globalToggle:
            String(localized: "statusBar.showThumbnails", locale: locale)
        case nil:
            String(localized: "statusBar.hideThumbnails", locale: locale)
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
        let refreshToken: Int
    }

    /// 空き容量の求め方は `VolumeCapacity` に一本化してある。ここで独自に
    /// 資源キーを読んでいた頃は、**小さなボリュームで「0 バイト空き」と
    /// 表示していた** — `…ForImportantUsage` が小容量のボリュームで 0 を
    /// 返すため（実測は `VolumeCapacity` の表）。コピー前の空き容量検査と
    /// 同じ値を見せることで、「表示上は足りるのに断られた」も防げる。
    private static func availableCapacity(of folder: URL?) async -> Int64? {
        guard let folder else { return nil }
        // **`Task.detached` では駄目** [NV6-01][NV6-02]。空き容量の問い合わせは
        // ボリュームへの syscall なので、応答しない共有を表示していると
        // ここでブロックする。detached も協調プールを使うため逃げ場にならない。
        // これはフォルダを移動するたびに走る、ごく普通の経路である。
        return await FileIO.perform { VolumeCapacity.available(at: folder) }
    }
}
