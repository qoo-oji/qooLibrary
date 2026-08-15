import QooInfrastructure
import QooKit
import SwiftUI

// MARK: - 行の分類

/// フォルダツリーの行が属するグループ [ユーザー要望: ボリューム／テンポラリ／
/// ライブラリのいずれに属するフォルダなのかでコンテキストメニューを
/// 切り替えられる仕組みにすること]。
///
/// `NavigationRoot`（タブがどちらの入口から来たか）より細かい — こちらは
/// テンポラリとライブラリを区別する。`NavigationRoot` は「登録フォルダ経由か
/// どうか」だけが分かればよい用途（ツリーの自動展開スコープ・「1階層上へ」の
/// 境界）のために作られたが、コンテキストメニューはテンポラリ固有の一括処理
/// （フェーズ3）とライブラリ固有のラベル操作（フェーズ2）を別々に足していく
/// 予定があるため、両者を型で区別できる必要がある。
enum FolderTreeGroup: Sendable, Equatable {
    case volume
    case temporary
    case library
}

/// ツリーのどの枝に属する行かを表す。`FolderTreeRow` の再帰で子孫へそのまま
/// 伝播させる（`registeredFolder`/`onRename` などルート行だけに渡す値とは
/// 対照的に、**必ず伝播させる**）。
///
/// 登録フォルダの ID・ルート URL も併せて持つため、この 1 つの値から
/// `FolderTreeGroup`（メニューの出し分け）と `NavigationRoot`（タブの入口）の
/// 両方を導出できる。以前は `rowNavigationRoot` と `FolderTreeNode.kind` の
/// 2 つに情報が分かれていたが、判断基準を 1 つに集約して取り違えを防ぐ。
enum FolderTreeBranch: Sendable, Equatable {
    case volume
    case temporary(id: UUID, rootURL: URL)
    case library(id: UUID, rootURL: URL)

    var group: FolderTreeGroup {
        switch self {
        case .volume: .volume
        case .temporary: .temporary
        case .library: .library
        }
    }

    var navigationRoot: NavigationRoot {
        switch self {
        case .volume: .volume
        case .temporary(let id, let rootURL), .library(let id, let rootURL):
            .registeredFolder(id: id, rootURL: rootURL)
        }
    }

    /// 登録フォルダの種別から枝を作る [`RegisteredFolderKind` は
    /// `QooInfrastructure` の永続化用の型]。
    static func registered(kind: RegisteredFolderKind, id: UUID, rootURL: URL) -> FolderTreeBranch {
        switch kind {
        case .library: .library(id: id, rootURL: rootURL)
        case .temporary: .temporary(id: id, rootURL: rootURL)
        }
    }
}

/// 行の役割。グループの最上位（ボリュームのマウントポイント、登録フォルダの
/// ルート）は、その配下の通常フォルダとは出せるメニュー項目が異なる
/// [ユーザー判断、`FolderTreeRowContext` の各 `allows...` 参照]。
enum FolderTreeRowRole: Sendable, Equatable {
    /// ボリュームのマウントポイント行（Macintosh HD・外部ボリューム等）。
    case volumeRoot
    /// ライブラリ／テンポラリとして登録されたフォルダそのものの行。
    case registeredRoot
    /// 上記いずれでもない、実フォルダを辿った先の通常の行。
    case plainFolder
}

/// 右クリックされた 1 行の文脈。`FolderTreeContextMenu` が項目を出し分ける
/// ための唯一の判断材料にする（View 側で個別に条件を書き散らさない）。
struct FolderTreeRowContext {
    let node: FolderTreeNode
    let branch: FolderTreeBranch
    let role: FolderTreeRowRole
    /// 登録ルート行のときだけ非 `nil` [RG-05][RG-06]。
    let registeredFolder: RegisteredFolder?

    var group: FolderTreeGroup { branch.group }
    var navigationRoot: NavigationRoot { branch.navigationRoot }
    var url: URL { node.url }
    /// 複製・エイリアス作成・「ここに圧縮」の書き込み先。中央ペインでは
    /// 「現在表示中のフォルダ」がこれに当たる。
    var parentURL: URL { node.url.deletingLastPathComponent() }

    /// この行が指すフォルダ**自体**を作り替える／**親フォルダへ書き込む**操作
    /// （名前を変更・複製・カット・ゴミ箱・圧縮・エイリアス作成・ロック）を
    /// 出すか。通常フォルダ行に限る [ユーザー判断]。
    ///
    /// - ボリュームのマウントポイントに対するこれらの操作は、実質「ボリューム
    ///   全体」が対象になり危険（複製・圧縮はボリューム全体の走査を始める）。
    /// - 登録フォルダのルートを消す・動かす・改名すると、Security-Scoped
    ///   Bookmark が解決不能になり登録自体が壊れる。片付けは明示的な
    ///   「登録解除」に一本化する。
    /// - 加えて、どちらのルートも**親フォルダへの書き込み権限を持たない**
    ///   （登録で得たスコープはその配下だけ、ボリュームの親は `/Volumes`）。
    ///   複製・エイリアス作成・「ここに圧縮」は書き込み先が親フォルダのため、
    ///   出したところで必ず権限エラーになる。
    ///
    /// **これは「その行から」の誤操作を防ぐだけで、フォルダ自体を保護する
    /// ものではない** [既知の限界、意図的にこの範囲に留めている]。同じ
    /// 実フォルダにボリュームの枝を辿って到達すれば `role` は `.plainFolder`
    /// になり、これらの項目が出る。中央ペインでも同じフォルダをそのまま
    /// ゴミ箱へ入れられる（1-13 以来の既存の挙動）ため、ツリーの一方の枝
    /// だけを塞いでも一貫性が無く、Finder のサイドバー（登録項目でも実体は
    /// 普通に削除できる）とも食い違う。登録フォルダの実体が失われた場合は
    /// ブックマークの解決に失敗し、`OfflineRegisteredFolderRow`（グレー
    /// アウト表示＋登録解除）へ自動的にフォールバックする [SB-05] ため、
    /// 復旧不能にはならない。
    var allowsStructuralOperations: Bool { role == .plainFolder }

    /// フォルダ自体を対象にするが構造は変えない操作（アプリケーションで開く・
    /// コピー・共有）を出すか。ボリュームのマウントポイントでは意味が薄い
    /// ため出さない [ユーザー判断: ボリュームのルート行はナビゲーション＋
    /// ユーティリティのみ]。
    var allowsItemOperations: Bool { role != .volumeRoot }
}

// MARK: - メニュー本体

/// フォルダツリー行のコンテキストメニュー [ユーザー要望: 中央ペインで
/// フォルダを右クリックしたときのメニューに原則あわせる]。
///
/// 中央ペイン（`FolderContentView.contextMenuContent(for:)`）との差分と理由:
/// - **展開系が無い**: ツリーはフォルダしか表示しないため、アーカイブを
///   右クリックする場面が存在しない。
/// - **複数選択が無い**: ツリーに複数選択の概念が無く、対象は常に 1 件。
///   そのため「選択項目で新規フォルダを作成」も出さない [ユーザー判断]。
/// - **名前の変更がアラート方式**: ツリー行は `DisclosureGroup` のラベル＋
///   タップでナビゲート、という構造でインライン編集の基盤が無いため
///   [ユーザー判断、既存の「表示名を変更…」と同じ体裁に揃える]。
/// - **「新規フォルダ」「ペースト」を追加**: どちらも「この行のフォルダの中へ」
///   作用する操作で、中央ペインでは空きスペースの右クリックに相当する
///   [ユーザー判断]。ツリーへの D&D は既に対応済み（[DD-05]）なので整合する。
/// - **「表示名を変更…」「登録解除」を追加**: 登録ルート行のみ [RG-05][RG-06]。
struct FolderTreeContextMenu: View {
    @Environment(\.locale) private var locale
    let context: FolderTreeRowContext
    let operations: FolderOperations
    let actions: FolderTreeContextMenuActions

    var body: some View {
        navigationSection
        groupSpecificSection
        creationSection
        editingSection
        trashSection
        compressionSection
        utilitySection
        lockSection
        registrationSection
    }

    // MARK: 開く／移動系

    @ViewBuilder
    private var navigationSection: some View {
        Button("action.open") { actions.open(context) }
        if context.allowsItemOperations {
            // フォルダは拡張子を持たないため `candidatesForFolders()` 側を使う
            // （`OpenWithMenu` が `isDirectory` で切り替える）。
            OpenWithMenu(url: context.url, isDirectory: true)
        }
        Button("folder.openInNewTab") { actions.openInNewTab(context) }
        Button("folder.openInNewWindow") { actions.openInNewWindow(context) }
    }

    // MARK: グループ固有の拡張スロット

    /// **ボリューム／テンポラリ／ライブラリごとの固有項目を足す場所**
    /// [ユーザー要望: 「ライブラリグループとテンポラリグループのフォルダに
    /// 対しては独自の項目追加が今後ある」]。
    ///
    /// 追加するときはこの `switch` に項目を書き、`FolderTreeContextMenuActions`
    /// に対応するクロージャを足して `FolderTreePane` から配線する。想定:
    /// - `.library`: ラベルの一括付与・保管庫へ移動 等（フェーズ2、ラベル
    ///   ドメイン型 `Label` の導入後）。
    /// - `.temporary`: 一括リネーム・変換リネーム・ライブラリへ投入 等
    ///   （フェーズ3）。
    ///
    /// いずれも `context.role` で「登録ルート自身か配下のフォルダか」を
    /// さらに絞り込めるようにしてある。
    @ViewBuilder
    private var groupSpecificSection: some View {
        switch context.group {
        case .volume:
            EmptyView()
        case .temporary:
            EmptyView()
        case .library:
            EmptyView()
        }
    }

    // MARK: この行のフォルダ「の中へ」作用する操作

    @ViewBuilder
    private var creationSection: some View {
        Divider()
        Button("action.newFolder") { actions.beginNewFolder(context) } // [FM-01]
        Button("action.paste") { operations.paste(into: context.url) }
            .disabled(!operations.canPaste)
            // Finder と同じく ⌥ で「ここに項目を移動」に入れ替わる
            // [Finder 対比監査。⌥ 代替の一覧と、対応しなかった項目の理由は
            // CLAUDE.md「Finder の ⌥ 代替項目」節を参照]。
            .modifierKeyAlternate(.option) {
                Button("folder.moveItemsHere") { operations.moveItemsHere(into: context.url) }
                    .disabled(!operations.canPaste)
            }
    }

    // MARK: 編集系

    @ViewBuilder
    private var editingSection: some View {
        if context.allowsStructuralOperations || context.allowsItemOperations {
            Divider()
        }
        if context.allowsStructuralOperations {
            Button("folder.renameEllipsis") { actions.beginRenameFolder(context) } // [FM-05]
            Button("folder.duplicate") { operations.duplicate([context.url], into: context.parentURL) } // [FM-02]
        }
        if context.allowsItemOperations {
            Button("action.copy") { operations.copyToPasteboard([context.url]) }
                // Finder と同じく ⌥ で「パス名をコピー」に入れ替わる [FM-10]。
                // 対にした結果、以前は無条件に出していた「パス名をコピー」も
                // 「コピー」と同じ条件（ボリュームのルート行では出さない）に
                // 従う——Finder のサイドバーもボリュームにはコピー系を出さない
                // ため、こちらの方が一貫する。
                .modifierKeyAlternate(.option) {
                    Button("folder.copyPath") { operations.copyPaths([context.url]) }
                }
        }
        if context.allowsStructuralOperations {
            Button("action.cut") { operations.cutToPasteboard([context.url]) }
        }
    }

    @ViewBuilder
    private var trashSection: some View {
        if context.allowsStructuralOperations {
            Divider()
            Button("folder.moveToTrash", role: .destructive) { operations.moveToTrash([context.url]) } // [FM-04]
                // Finder と同じく ⌥ で「すぐに削除…」に入れ替わる [FM-14]。
                // 対にしたことで「完全削除はゴミ箱と同じ条件でしか出さない」
                // （ボリュームのマウントポイントと登録ルートには出さない）が
                // 構造的に保証される — 特に登録ルートを完全削除すると復元手段が
                // 無く、`OfflineRegisteredFolderRow` へのフォールバック [SB-05]
                // すら意味を成さなくなる。
                .modifierKeyAlternate(.option) {
                    Button("folder.deletePermanentlyEllipsis", role: .destructive) {
                        operations.deletePermanently([context.url])
                    }
                }
        }
    }

    // MARK: 圧縮

    /// 中央ペインは「圧縮／展開」サブメニューだが、ツリーには展開対象
    /// （アーカイブ）が並ばないため圧縮だけのサブメニューにする。
    @ViewBuilder
    private var compressionSection: some View {
        if context.allowsStructuralOperations {
            Divider()
            Menu("folder.compressSubmenu") {
                Button("folder.compressHere") { operations.compressHere([context.url], into: context.parentURL) } // [AR-10]
                    // Finder と同じく ⌥ で「パスワード付きで圧縮」に入れ替わる。
                    // 既定の圧縮形式が暗号化に対応しているときだけ差し替える
                    // （`FolderOperations.canCompressWithPassword` 参照）。
                    .modifierKeyAlternate(.option) {
                        if operations.canCompressWithPassword {
                            Button("folder.compressHereWithPassword") {
                                operations.compressHereWithPassword([context.url], into: context.parentURL)
                            }
                        }
                    }
                Button("folder.compressEllipsis") { operations.compressWithDialog([context.url], startingIn: context.parentURL) } // [AR-11]
            }
        }
    }

    // MARK: 副次的な操作

    @ViewBuilder
    private var utilitySection: some View {
        Divider()
        Button("folder.revealInFinder") { operations.revealInFinder([context.url]) } // [FM-09]
        if context.allowsItemOperations {
            ShareLink("folder.shareEllipsis", items: [context.url])
        }
        if context.allowsStructuralOperations {
            Button("folder.createAlias") { operations.createAliases(for: [context.url], in: context.parentURL) }
        }
        // 「パス名をコピー」「すぐに削除…」はここに退避していた「その他」
        // サブメニューではなく、Finder と同じくそれぞれ「コピー」「ゴミ箱に
        // 入れる」の ⌥ 代替になった（`editingSection`／`trashSection` 参照）。
    }

    // MARK: ロック

    @ViewBuilder
    private var lockSection: some View {
        if context.allowsStructuralOperations {
            Divider()
            Button(context.node.isLocked ? "folder.unlock" : "folder.lock") {
                operations.setLocked([context.url], locked: !context.node.isLocked)
            }
        }
    }

    // MARK: 登録の管理（ライブラリ／テンポラリのルート行のみ）

    @ViewBuilder
    private var registrationSection: some View {
        if let registeredFolder = context.registeredFolder {
            Divider()
            Button("folderTree.renameDisplayNameEllipsis") { actions.beginRenameDisplayName(registeredFolder) } // [RG-05]
            Button("folderTree.unregister") { actions.unregister(registeredFolder) } // [RG-06 の簡易版]
        }
    }
}

/// `FolderTreeContextMenu` のうち、`FolderOperations`（ファイル操作の共通層）
/// では完結せず `FolderTreePane` 側の状態（ナビゲーション・アラート・登録
/// ストア）を必要とする項目のための橋渡し。
///
/// グループ固有の項目を足すときは、ここへ対応するクロージャを追加する
/// [`FolderTreeContextMenu.groupSpecificSection` 参照]。
struct FolderTreeContextMenuActions {
    var open: (FolderTreeRowContext) -> Void = { _ in }
    var openInNewTab: (FolderTreeRowContext) -> Void = { _ in }
    var openInNewWindow: (FolderTreeRowContext) -> Void = { _ in }
    /// フォルダ名変更のアラートを開く（実際のリネームは `FolderOperations`）。
    var beginRenameFolder: (FolderTreeRowContext) -> Void = { _ in }
    /// 新規フォルダ名入力のアラートを開く。
    var beginNewFolder: (FolderTreeRowContext) -> Void = { _ in }
    /// 登録フォルダの表示名変更アラートを開く [RG-05]。
    var beginRenameDisplayName: (RegisteredFolder) -> Void = { _ in }
    /// 登録解除 [RG-06 の簡易版]。
    var unregister: (RegisteredFolder) -> Void = { _ in }
}
