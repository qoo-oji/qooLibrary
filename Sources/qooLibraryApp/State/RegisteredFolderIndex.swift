import Foundation
import Observation
import QooInfrastructure
import QooKit

/// 登録フォルダ（ライブラリ／テンポラリ）の、解決済み URL つき一覧をメイン
/// アクタ上に保持する軽量なキャッシュ [1-16 移動メニュー]。
///
/// **メニューバー（`.commands`）から登録フォルダを参照するために必要**。
/// `RegisteredFolderStore` は `actor` のため `await` なしには読めないが、
/// `.commands` のビューは `.task` を持てず、そもそもメニューバーのメニューは
/// アプリ起動時に一度構築されたあと「メニューを開いた」だけでは再評価されない
/// （1-14 の ⌥ 代替調査で実測済み）。一方で `@Observable` な状態の変化に
/// よる再評価は起きる（`CommandStack.shared.canUndo` が Undo メニューの
/// 有効/無効を動かしているのが既存の実例）ため、非同期に解決した結果を
/// この `@Observable` に載せておき、メニュー側はそれを同期的に読む。
///
/// `FolderTreePane` も同じ情報を自前の `@State` に持っているが、そちらは
/// ツリー描画のための `FolderTreeNode` を伴い、オフライン時の専用行
/// [SB-05] など表示都合の状態も抱えている。ここはメニュー用に「名前と
/// 解決済み URL」だけを持つ最小限の別物として用意し、同期は
/// `FolderTreePane.reloadRegisteredFolders()` からの `refresh()` 呼び出し
/// 1 行で取る [設計判断: 片方を他方へ寄せる大きめの refactor より、更新経路を
/// 1 本に集約するほうが安全と判断した]。
@MainActor
@Observable
public final class RegisteredFolderIndex {
    public static let shared = RegisteredFolderIndex()

    /// 登録フォルダ 1 件。解決に失敗したもの（ボリューム未接続など [SB-05]）は
    /// メニューに出しても選べないため、そもそも含めない。
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let displayName: String
        public let url: URL
        /// この登録フォルダの配下でサムネイルを常に非表示にするか [DS-04]。
        public let thumbnailsAlwaysHidden: Bool
    }

    public private(set) var library: [Entry] = []
    public private(set) var temporary: [Entry] = []

    private init() {}

    /// 種別を問わず ID で 1 件引く。呼び出し側（`WindowState`・フォルダツリーの
    /// コンテキストメニュー）は `NavigationRoot`/`FolderTreeBranch` から ID しか
    /// 持っていないため、ライブラリ／テンポラリの両方を横断して探す。
    public func entry(id: UUID) -> Entry? {
        library.first { $0.id == id } ?? temporary.first { $0.id == id }
    }

    /// [DS-04] 未知の ID（未登録・オフラインで解決できない）は `false`
    /// ——「分からないから隠す」より「分からないなら通常どおり」のほうが
    /// 驚きが少ないため。
    public func hidesThumbnails(registeredFolderID id: UUID) -> Bool {
        entry(id: id)?.thumbnailsAlwaysHidden ?? false
    }

    public func refresh() async {
        // **状態を見て、入って辿れるものだけを載せる** [1-17]。
        //
        // 以前は `resolvedURL(for:)` を直に呼んでいたため、ゴミ箱へ移した
        // 登録フォルダもそのまま並んでいた——ブックマークは inode を追跡し
        // 解決に成功し続けるので [BM-2]、URL は「ゴミ箱の中」を指す。
        // 結果、ツリーでは入れないようにしたのに**「移動」メニューと
        // 起動時フォルダからは素通りで入れて、中で自由に書けた**。
        // 「同じ機能に複数の到達経路があり、片方だけ塞いで取り残す」という、
        // 1-12 のアプリ関連付けで実際に踏んだ形そのもの。
        let states = await RegisteredFolderStore.shared.states()
        library = Self.entries(from: states, kind: .library)
        temporary = Self.entries(from: states, kind: .temporary)
        // 登録フォルダの増減・表示名変更・DS-04 の切替・アクセス権やボリューム
        // の変化（`SessionState.reloadToken` 経由）は、すべてこの refresh() に
        // 集約されている（更新経路 1 本、型のコメント参照）。バックグラウンドの
        // 動画サムネイル生成 [9.6 節] も「対象が変わった」合図としてここで
        // 掃引をやり直す — 起動時の最初の掃引も `qooLibraryApp.init()` の
        // refresh() 呼び出しがそのまま兼ねる。restart() 側に短い待ち合わせが
        // あるため、連続で呼ばれても掃引は 1 回にまとまる。
        BackgroundThumbnailWarmer.shared.restart()
    }

    /// **`allowsNavigation` が真のものだけ**を載せる [1-17]。オフライン・
    /// ゴミ箱・消失の登録は「移動」メニューにも起動時フォルダにも出さない
    /// ——出しても開けないか、開いてはいけない場所である。
    ///
    /// 副次的に、バックグラウンドの動画サムネイル生成 [9.6 節] もこの一覧を
    /// 掃くので、ゴミ箱の中や未接続のボリュームを掃きに行かなくなる。
    private static func entries(from states: [RegisteredFolderState], kind: RegisteredFolderKind) -> [Entry] {
        // 並びはツリーと同じ保存順 [RG3-33]（`states()` が配列順で返す）。
        states
            .filter { $0.folder.kind == kind }
            .compactMap { state in
                guard state.status.allowsNavigation, let url = state.status.resolvedURL else { return nil }
                return Entry(
                    id: state.folder.id,
                    displayName: state.folder.displayName,
                    url: url,
                    thumbnailsAlwaysHidden: state.folder.hidesThumbnails
                )
            }
    }
}
