import AppKit
import QooInfrastructure
import QooKit
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
/// アイコン表示の並びの寸法。
///
/// **矢印キーの上下移動には「1 行が何列か」が要る**が、`LazyVGrid` は自分が
/// 何列で並べたかを教えてくれない。実測幅から同じ式で計算し直すしかないので、
/// 式そのものをここへ出して**レイアウトと計算が別々に変わらない**ようにする。
enum IconGridMetrics {
    static let spacing: CGFloat = Tokens.spacing.m
    /// グリッド自身の左右の余白（`LazyVGrid` に付けている `.padding`）。
    static let horizontalPadding: CGFloat = Tokens.spacing.m

    /// 1 項目の最小幅。アイコンの左右に名前とパディングのぶんを足す。
    static func minimumItemWidth(iconSize: Double) -> CGFloat { iconSize + 32 }

    /// `width` の中に何列並ぶか。`LazyVGrid(.adaptive)` と同じ数え方
    /// （項目 n 個には間隔が n-1 個ぶん入る）。
    /// - Parameter width: グリッドを載せている**スクロールビューの実測幅**。
    ///   グリッド自身の左右パディングはここで差し引く [レビューで発見: 引かないと
    ///   列数が 1 つずれ、矢印キーが別の項目へ飛ぶ]。
    static func columnCount(width: CGFloat, iconSize: Double) -> Int {
        let minimum = minimumItemWidth(iconSize: iconSize)
        let available = width - horizontalPadding * 2
        guard available > 0, minimum > 0 else { return 1 }
        return max(1, Int((available + spacing) / (minimum + spacing)))
    }
}

struct IconGridView<MenuContent: View>: View {
    let entries: [FolderEntry]
    @Binding var selection: Set<URL>
    let iconSize: Double
    /// サムネイル・カバー画像を出さない [DS-01][DS-04]。実効値の合成は
    /// `WindowState.thumbnailHiddenReason` が済ませており、ここは結果だけを
    /// 受け取る。
    let thumbnailsHidden: Bool
    let dragNamespace: Namespace.ID
    /// 衝突の判断・進捗・キャンセルを担う共有レイヤ [FM-11][UI-09]。
    /// フォルダ行へのドロップがここを通る。
    let operations: FolderOperations
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
        [GridItem(.adaptive(minimum: IconGridMetrics.minimumItemWidth(iconSize: iconSize)), spacing: IconGridMetrics.spacing)]
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
            operations: operations,
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
        let operations: FolderOperations
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
                    .modifier(DropIntoFolderModifier(entry: entry, operations: operations, reload: onReload, onFailure: onDropFailure, targetedURL: $dropTargetedURL))
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
    /// フォルダ直下のファイルのカバー（最大 `AppLimits.Thumbnail.defaultFolderCoverCount`
    /// 枚）［ユーザー要望］。空ならフォルダアイコンだけを描く。
    @State private var folderCovers: [NSImage] = []

    var body: some View {
        Group {
            if entry.isDirectory {
                // フォルダは**常にフォルダの形**で描き、中身を中に収める
                // ［ユーザー判断: フォルダとファイルを一目で見分けられること
                // を優先］。以前は直下に画像があるフォルダだけカバーが全面に
                // 出てファイルと区別が付かなかった。
                FolderCoverIcon(
                    folderIcon: FileIconProvider.shared.icon(for: entry.url),
                    covers: folderCovers,
                    size: size
                )
            } else if let image {
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
            folderCovers = []
            // [DS-01] 非表示中は汎用アイコン（上の `else` 側）のまま。
            // [DS-05] 要求そのものを出さないので生成もキャッシュも起きない。
            guard !thumbnailsHidden else { return }
            // **どちらの経路も `maxPixelSize` は同じ `size * 2`（Retina 相当）**。
            // フォルダのカバーは小さく描かれるので本来もっと粗くてよいが、
            // `CoverImageCache` のキーは `FileIdentity` だけで**要求サイズを
            // 含まない**ため、ここで小さく要求すると、その同じファイルを単体の
            // セルとして表示したときに粗いキャッシュを掴んでしまう。
            if entry.isDirectory {
                let images = await ThumbnailService.shared.folderCoverThumbnails(
                    for: entry.url, maxPixelSize: Int(size * 2)
                )
                folderCovers = images.map(Self.nsImage(from:))
            } else {
                guard let cgImage = await ThumbnailService.shared.thumbnail(
                    for: entry.url, maxPixelSize: Int(size * 2)
                ) else { return }
                image = Self.nsImage(from: cgImage)
            }
        }
    }

    private static func nsImage(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// フォルダアイコンと、その前面パネルの中に収めた中身のカバー
/// ［ユーザー要望: 「フォルダアイコンの中に複数のサムネイルを表示したい」、
/// レイアウトは「フォルダの形の中に収める」・最大 3 枚］。
///
/// 背景は SF Symbol の代用ではなく **`NSWorkspace` が返す実際のフォルダ
/// アイコン**（`FileIconProvider`）。カスタムフォルダアイコンもそのまま活きる。
///
/// ## 配置の数値は実測で決めている
/// 512px で描画したフォルダアイコンのアルファを 1 行ずつ走査して、
/// 不透明な範囲が `y = 0.131…0.893`、タブが終わって前面パネルが全幅に達するのが
/// `y = 0.221`、水平は `x = 0.031…0.967` であることを確認した。
/// **目分量で決めない**——同種の見た目合わせで、指定サイズを揃えても実寸が
/// 一致しないことを過去に踏んでいる（CLAUDE.md「アイコンの大きさを揃える」）。
private struct FolderCoverIcon: View {
    let folderIcon: NSImage
    let covers: [NSImage]
    let size: Double

    /// カバーを置く縦方向の範囲。**フォルダの縁がはっきり残る**高さにする
    /// ——最初の実装はパネルいっぱいに敷いてしまい、フォルダの絵がタブしか
    /// 見えなくなった。
    private static let contentTop = 0.310
    private static let contentBottom = 0.800

    /// **次のカバーを、そのカバー自身の幅の何割ぶん右へずらすか。**
    /// `0.70` なら 30% 重なる。
    ///
    /// ずらし量を「アイコン幅に対する固定値」ではなく**各カバー自身の幅の比**
    /// で決めるのが要点［ユーザー指摘: 「本というか画像のアスペクト比に
    /// 依存する気がします」］。横長のサムネイルは幅も広いので、比で持っておけば
    /// 重なり具合が縦長・横長のどちらでも同じ見え方になる。
    ///
    /// 束が占める、アイコン全体の横幅に対する目標比
    /// ［ユーザー指定: 当初 80% にしたが「少し横幅を使いすぎている」ため下げた］。
    private static let targetBundleWidth = 0.75

    /// 隣のカバーが最低限どれだけ右へはみ出すか（アイコン全体に対する比）。
    /// **これを下回ると後ろのカバーが前のカバーに完全に隠れる。**
    private static let minPeek = 0.10

    /// ずらし幅の上限（カバー 1 枚の幅に対する比）。`0.75` なら必ず 25% 重なる。
    /// 2 枚のときに束を目標幅まで広げようとすると隙間が空いてしまうため、
    /// 重なりを保つほうを優先する。
    private static let maxStepRatio = 0.75

    /// カバー 1 枚が取ってよい最大の幅（アイコン全体に対する比）。
    ///
    /// **横長のサムネイルで破綻させないための要**［ユーザー指定: 「動画のように
    /// サムネイルが 16:9 の場合でも破綻しないように」］。高さを基準に幅を出すと
    /// 16:9（幅 ÷ 高さ ≒ 1.78）は幅がアイコンの 87% に達してフォルダから
    /// はみ出すため、**比率は一切変えず、この幅に当たったら高さのほうを下げる**。
    ///
    /// 値は「**最大枚数を最小のはみ出し量で重ねたときに、束が目標幅に収まる**」
    /// ことから決まる: `0.75 − 0.10 × (3 − 1) = 0.55`。
    ///
    /// **最大枚数を基準にするのは、1 枚のフォルダと 3 枚のフォルダでカバーの
    /// 大きさを変えないため**［ユーザー指定］。また `stepRatio`（幅に対する
    /// 一定比）で上限を決めていた頃は 0.33 までしか取れず、16:9 だと高さが
    /// アイコンの 18% しか無くて何の動画か分からなかった
    /// ［ユーザー指摘］——横長は縦にもカスケードして判別できるので、
    /// 横方向は深く重ねてよい、というのがこの決め方の根拠。
    private static var maxCoverWidth: Double {
        targetBundleWidth - minPeek * Double(max(1, AppLimits.Thumbnail.defaultFolderCoverCount - 1))
    }

    var body: some View {
        ZStack {
            Image(nsImage: folderIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
            if !covers.isEmpty {
                coverRow
            }
        }
        .frame(width: size, height: size)
    }

    private var coverRow: some View {
        let placed = Self.layout(covers: covers, size: size)
        let totalWidth = placed.map { $0.x + $0.width }.max() ?? 0
        let count = Double(covers.count)

        return ZStack {
            ForEach(Array(placed.enumerated()), id: \.offset) { index, item in
                Image(nsImage: item.cover)
                    .resizable()
                    // **切り抜かない。** 枠は画像自身の比率で作ってあるので、
                    // `.fit` でも余白は出ない。
                    .aspectRatio(contentMode: .fit)
                    .frame(width: item.width, height: item.height)
                    // 枠線は付けず、影だけで背後のカバーとフォルダから分離する。
                    .shadow(color: .black.opacity(0.5), radius: size * 0.016, x: 0, y: size * 0.005)
                    // 束全体の中心が揃うよう左端から順に置き、縦は**上端を基準に
                    // 下げていく**（＝左上から右下へ流れる）。縦に余りが無い
                    // 縦長カバーでは `drop` が 0 なので上下とも揃う。
                    .offset(
                        x: -totalWidth / 2 + item.x + item.width / 2,
                        y: size * (Self.contentTop - 0.5) + item.drop + item.height / 2
                    )
                    // **先頭を手前に。** 自然順の 1 枚目がカバーとして最も読め、
                    // 後ろの 2・3 枚目が右へ少しずつ覗く。
                    .zIndex(count - Double(index))
            }
        }
    }

    private struct PlacedCover {
        let cover: NSImage
        let width: Double
        let height: Double
        /// 束の左端からの位置。
        let x: Double
        /// 上端を `contentTop` からどれだけ下げるか。横長のカバーで縦に余りが
        /// 出たときだけ 0 より大きくなる。**左上から右下へ**流れる
        /// ［ユーザー指定］ため、後ろの段ほど大きくなる。
        let drop: Double
    }

    /// 各カバーの大きさと位置を決める。**画像自身の縦横比を歪めない**のが前提。
    ///
    /// - 高さは `contentTop…contentBottom` いっぱいを基準にする（**枚数では
    ///   変えない**［ユーザー指定］）。
    /// - 幅はその高さと画像自身の比率から決まる。``maxCoverWidth`` を超える
    ///   横長（16:9 の動画など）は、比率を変えずに高さのほうを下げる。
    /// - 次のカバーは、**そのカバー自身の幅**の ``stepRatio`` ぶん右へ置く。
    /// - 横長で縦に余りが出たときは、**下へもずらして余白を使い切る**
    ///   ［ユーザー要望: 「横長画像の場合は左右だけでなく上下にもずらせば
    ///   無駄なくスペースを使える」「左上から右下へ向かうようにずらすほうが
    ///   自然」］。縦長カバーでは余りが無いので自動的にずれ幅 0 になり、
    ///   従来の見え方は変わらない。
    private static func layout(covers: [NSImage], size: Double) -> [PlacedCover] {
        let contentHeight = size * (contentBottom - contentTop)
        let widthLimit = size * maxCoverWidth

        // 先に大きさだけ決める。縦のずらし幅は全カバーの高さが揃ってからでないと
        // 決められない（一番背の高いカバーがはみ出さない範囲に収める必要がある）。
        var sizes: [(width: Double, height: Double)] = []
        for cover in covers {
            let pixels = cover.size
            let aspect = pixels.height > 0 ? Double(pixels.width / pixels.height) : 0.68
            var height = contentHeight
            var width = height * aspect
            if width > widthLimit {
                width = widthLimit
                height = width / aspect
            }
            sizes.append((width, height))
        }

        // 縦のずらし幅は「どのカバーも下端が `contentBottom` を越えない」最大値。
        // i 段目の下端は `contentTop + i×drop + height_i` なので、
        // すべての i について `i×drop ≦ contentHeight - height_i` を満たす必要がある。
        var verticalStep = Double.greatestFiniteMagnitude
        for (index, item) in sizes.enumerated() where index > 0 {
            verticalStep = min(verticalStep, (contentHeight - item.height) / Double(index))
        }
        if sizes.count < 2 { verticalStep = 0 }
        verticalStep = max(0, min(verticalStep, contentHeight))

        // 横のずらし幅は「束が目標幅になる値」。ただし重なりが浅くなりすぎない
        // 上限で頭打ちにする（2 枚のときに目標幅まで広げると隙間が空くため）。
        let widest = sizes.map(\.width).max() ?? 0
        let desiredStep = sizes.count > 1
            ? (size * targetBundleWidth - widest) / Double(sizes.count - 1)
            : 0
        let step = max(0, min(desiredStep, widest * maxStepRatio))

        // 束が縦を使い切らないときは**上下中央**に置く［ユーザー要望: 横長 1 枚
        // のフォルダで上に貼り付いて見えたため］。1 枚だけの特例にはせず、
        // カスケードが縦を余らせるケース全般に効かせる。縦長カバーのように
        // ちょうど埋まる場合は補正が 0 になり、見え方は変わらない。
        let bundleHeight = sizes.enumerated()
            .map { verticalStep * Double($0.offset) + $0.element.height }
            .max() ?? 0
        let verticalCentering = max(0, (contentHeight - bundleHeight) / 2)

        var placed: [PlacedCover] = []
        var x = 0.0
        for (index, item) in sizes.enumerated() {
            if index > 0 {
                let previous = placed[index - 1]
                // 幅がばらつくフォルダ（縦長のコミックと 16:9 の動画が混在する等）
                // では、一定のずらし幅だけだと**細いカバーが前のカバーに完全に
                // 隠れる**ことがある。右端が必ず `minPeek` ぶんはみ出す位置まで
                // 押し出す。
                let byStep = previous.x + step
                let byPeek = previous.x + previous.width + size * minPeek - item.width
                x = max(byStep, byPeek)
            }
            placed.append(PlacedCover(
                cover: covers[index],
                width: item.width,
                height: item.height,
                x: x,
                drop: verticalCentering + verticalStep * Double(index)
            ))
        }
        return placed
    }
}
