import AppKit
import QooInfrastructure
import SwiftUI

/// アイコン表示 [IV-01/08/09、PF-10]。`Table`/`List` と違い選択・ドラッグ＆
/// ドロップ・コンテキストメニューまわりの AppKit 標準機能が一切無いため、
/// このファイルで手動再現する。
///
/// 具体的に失っているもの・妥協した点:
/// - `.contextMenu(forSelectionType:)`（`FolderContentView` の `Table` が使う、
///   選択されていない行を右クリックしたときに Finder 流の青い枠線を自動描画
///   してくれる AppKit 標準 API）は `List`/`Table` 専用で、`LazyVGrid` には
///   使えない。そのため各セルへ個別に `.contextMenu` を付ける旧来方式に戻して
///   おり、非選択項目を右クリックしたときの枠線表示は無い
///   [既知の制限、必要になれば手動の枠線描画を追加検討]。
/// - 選択・ダブルクリック・D&D は `FolderContentView` の `rowCell`/
///   `handleSingleClick` と同じロジックをセル単位で再現している
///   （`onSingleClick` クロージャで実際の選択処理自体は `FolderContentView`
///   に委譲し、二重実装を避けている）。
struct IconGridView<MenuContent: View>: View {
    let entries: [FolderEntry]
    @Binding var selection: Set<URL>
    let iconSize: Double
    /// サムネイル・カバー画像を出さない [DS-01][DS-04]。実効値の合成は
    /// `WindowState.thumbnailHiddenReason` が済ませており、ここは結果だけを
    /// 受け取る。
    let thumbnailsHidden: Bool
    let dragNamespace: Namespace.ID
    /// ダブルクリック時に呼ばれる。フォルダなら移動、ファイルなら関連付けた
    /// アプリで開く、の判定は呼び出し側（`FolderContentView.openEntries`）に
    /// 委譲する [実機検証で発見したバグの修正: 以前はここで `isDirectory` を
    /// 見てフォルダのときだけ呼んでいたため、ファイルのダブルクリックが
    /// 何も起きなかった]。
    let onOpenEntry: (FolderEntry) -> Void
    let onSingleClick: (FolderEntry) -> Void
    let onReload: () -> Void
    let onDropFailure: (String) -> Void
    /// 空きスペースの右クリック（`urls` が空集合）も同じクロージャで扱う
    /// （`FolderContentView.contextMenuContent(for:)` が既に空集合の場合の
    /// 「新規フォルダ」「ペースト」を用意しているため、ここで別途持つ必要が無い）。
    @ViewBuilder let contextMenuContent: (Set<URL>) -> MenuContent
    /// Finder 流のインライン名前編集 [ユーザー要望]。トリガー判定
    /// （「既に選択済みの項目をもう一度クリック」の遅延判定）自体は
    /// `FolderContentView.handleSingleClick` に委譲しており（`onSingleClick`
    /// 経由、二重実装を避ける）、ここでは `renamingURL` に応じてセルの表示を
    /// 名前 `Text` から `TextField` へ切り替えるだけを担当する。
    let renamingURL: URL?
    @Binding var renameText: String
    var isRenameFieldFocused: FocusState<Bool>.Binding
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    /// 選択ハイライトの濃淡切り替え用 [実機検証時のユーザー指摘: 独自の
    /// 半透明アクセントカラーだと Finder のような青にならない]。`Table` は
    /// AppKit がフォーカス状態に応じて濃い青（フォーカスあり）と灰色
    /// （フォーカスなし）を自動的に切り替えるが、`LazyVGrid` にはその仕組みが
    /// 無いため、`FolderContentView` の `isListFocused` をそのまま受け取って
    /// 同じ判定をここでも再現する。
    let isFocused: Bool
    /// 名前が長すぎるときの省略位置 [ユーザー要望、環境設定「表示」タブ・
    /// `FolderContentView` の名前列と同じキーを共有する]。
    @AppStorage("qoo.folderList.nameTruncationMode") private var nameTruncationMode: NameTruncationMode = .tail

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 32), spacing: Tokens.spacing.m)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Tokens.spacing.l) { // [PF-10] 可視範囲のみ描画
                ForEach(entries) { entry in
                    cell(for: entry)
                }
            }
            .padding(Tokens.spacing.m)
        }
        .contentShape(Rectangle())
        // 行の `.contextMenu` がヒットしない空きスペースでの右クリック用
        // （`Table` 側の `.contextMenu(forSelectionType:)` が空集合のときと
        // 同じ役割）。
        .contextMenu {
            contextMenuContent([])
        }
        // [DD-02][設計判断] `URL` は既に `Transferable`。ドラッグされたセルの
        // `containerItemID`（＝ URL 自身）の配列がそのままペイロードになる。
        .dragContainer(for: URL.self, itemID: \.self, in: dragNamespace) { draggedItemIDs in
            draggedItemIDs
        }
        .dragContainerSelection(Array(selection), containerNamespace: dragNamespace)
    }

    @ViewBuilder
    private func cell(for entry: FolderEntry) -> some View {
        let isRenaming = renamingURL == entry.url
        VStack(spacing: Tokens.spacing.xs) {
            ThumbnailImage(entry: entry, size: iconSize, thumbnailsHidden: thumbnailsHidden)
            if isRenaming {
                // Finder 流のインライン名前編集 [ユーザー要望]。
                TextField("column.name", text: $renameText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: Tokens.fontSize.caption))
                    .focused(isRenameFieldFocused)
                    .onSubmit { onCommitRename() }
                    .onExitCommand { onCancelRename() }
                    .onAppear {
                        isRenameFieldFocused.wrappedValue = true
                        // フィールドエディタが割り当てられた後でないと選択範囲を
                        // 操作できないため 1 サイクル遅らせる。
                        DispatchQueue.main.async {
                            InlineRenameSupport.selectBaseNameIfApplicable(for: entry)
                        }
                    }
                    .onChange(of: isRenameFieldFocused.wrappedValue) { _, focused in
                        if !focused, renamingURL == entry.url {
                            onCommitRename()
                        }
                    }
                    .frame(height: Tokens.fontSize.caption * 2.4)
            } else {
                Text(entry.name)
                    .font(.system(size: Tokens.fontSize.caption))
                    .lineLimit(2)
                    .truncationMode(nameTruncationMode.swiftUIMode) // [ユーザー要望] 名前列と同じ設定を共有する。
                    .multilineTextAlignment(.center)
                    // 濃い青の背景に対して黒文字だとコントラストが低いため、
                    // Finder と同じくフォーカスありの選択中は白文字にする。
                    .foregroundStyle(
                        selection.contains(entry.url) && isFocused
                            ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary
                    )
                    .frame(height: Tokens.fontSize.caption * 2.4)

                // 検索結果のときだけ、どの階層のものかを名前の下に添える
                // [ユーザー要望、リスト表示の「場所」列と同じ情報]。空
                // （＝検索の起点直下）のときは行そのものを出さない。
                if !entry.relativeLocation.isEmpty {
                    Text(entry.relativeLocation)
                        .font(.system(size: Tokens.fontSize.caption))
                        .lineLimit(1)
                        .truncationMode(.head) // 末尾（＝直近の親フォルダ）を優先して見せる
                        .foregroundStyle(.secondary)
                        .help(entry.relativeLocation)
                }
            }
        }
        .padding(Tokens.spacing.xs)
        .frame(width: iconSize + 32)
        // 選択のハイライトは AppKit のシステム標準色を使い、`Table` と同じく
        // フォーカスの有無で濃い青／灰色を切り替える
        // [実機検証時のユーザー指摘: 独自の半透明アクセントカラーだと Finder
        // のような青にならない]。
        .background(selectionBackground(for: entry))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuContent(targets(for: entry))
        }
        .modifier(IconCellGestures(
            isEnabled: !isRenaming,
            entry: entry,
            dragNamespace: dragNamespace,
            onOpenEntry: onOpenEntry,
            onSingleClick: onSingleClick,
            onReload: onReload,
            onDropFailure: onDropFailure
        ))
    }

    /// セルの選択・ダブルクリック・D&D 用ジェスチャ一式。`isEnabled == false`
    /// （インライン編集中）のときは何も付けない
    /// （`FolderContentView.rowCell` の `isRenaming` 分岐と同じ理由: `TextField`
    /// 自身のクリックが誤って選択操作やリネームの再トリガーとして扱われるのを
    /// 防ぐため）。
    private struct IconCellGestures: ViewModifier {
        let isEnabled: Bool
        let entry: FolderEntry
        let dragNamespace: Namespace.ID
        let onOpenEntry: (FolderEntry) -> Void
        let onSingleClick: (FolderEntry) -> Void
        let onReload: () -> Void
        let onDropFailure: (String) -> Void
        /// アイコン表示は1セル＝1エントリのため `Table` のような列分割の
        /// 問題は無いが、`DropIntoFolderModifier` の API を統一するため
        /// セルごとに専用の `@State` を経由したバインディングを渡す
        /// [`DropIntoFolderModifier` のコメント参照]。
        @State private var dropTargetedURL: URL?

        func body(content: Content) -> some View {
            if isEnabled {
                content
                    .onTapGesture(count: 2) {
                        onOpenEntry(entry)
                    }
                    // `FolderContentView.rowCell` と同じ理由で
                    // `.simultaneousGesture` にしている（単発クリックの選択発火を
                    // ダブルクリック判定の待ち時間から外し、即座に反応させる）。
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        onSingleClick(entry)
                    })
                    .draggable(containerItemID: entry.url, containerNamespace: dragNamespace)
                    .modifier(DropIntoFolderModifier(entry: entry, reload: onReload, onFailure: onDropFailure, targetedURL: $dropTargetedURL))
            } else {
                content
            }
        }
    }

    /// 右クリックした項目が現在の選択に含まれていれば選択全体、そうでなければ
    /// その1件だけを対象にする（Finder と同じ規則。`Table` 側は AppKit が
    /// 自動でやってくれるが、`LazyVGrid` では自前で判定する）。
    private func targets(for entry: FolderEntry) -> Set<URL> {
        selection.contains(entry.url) ? selection : [entry.url]
    }

    private func selectionBackground(for entry: FolderEntry) -> Color {
        guard selection.contains(entry.url) else { return .clear }
        return isFocused
            ? Color(nsColor: .selectedContentBackgroundColor)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }
}

/// 1セル分のサムネイル。生成中はプレースホルダ [IV-08]。`ThumbnailService`
/// が非同期に解決し、`.task(id:)` によりセルが再利用されて対象の `entry` が
/// 変わったら（`LazyVGrid` のスクロール外へ流れて別の項目に再利用されたら）
/// 自動的に前のタスクをキャンセルして再取得する。
private struct ThumbnailImage: View {
    let entry: FolderEntry
    let size: Double
    let thumbnailsHidden: Bool

    /// `.task(id:)` の識別子。**サムネイル表示の可否も含める**のが要点
    /// [DS-05]。これにより、
    /// - 非表示に切り替えた瞬間に生成中のタスクが取り消され（無駄な I/O が
    ///   その場で止まる）、
    /// - 表示に戻した瞬間にタスクが再実行されて生成が始まる
    ///   （「再表示時に生成する」）、
    /// の両方が SwiftUI の標準の仕組みだけで成立する。
    private struct RequestKey: Equatable {
        let url: URL
        let hidden: Bool
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // サムネイル生成中・生成不可（大半のファイルはここに留まる）は
                // Finder と同じアイコンを表示する [ユーザー要望: SF Symbol の
                // 代用アイコンでは視認性が良くない]。
                Image(nsImage: FileIconProvider.shared.icon(for: entry.url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .task(id: RequestKey(url: entry.url, hidden: thumbnailsHidden)) {
            image = nil
            // [DS-01] 非表示中は汎用アイコン（上の `else` 側）のまま。
            // [DS-05] 要求そのものを出さないので生成もキャッシュも起きない。
            guard !thumbnailsHidden else { return }
            // 最大ピクセルサイズは表示サイズの2倍（Retina 相当）を目安にする。
            guard let cgImage = await ThumbnailService.shared.thumbnail(for: entry.url, maxPixelSize: Int(size * 2)) else {
                return
            }
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}
