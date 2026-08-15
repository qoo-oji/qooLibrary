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
        async let libraries = RegisteredFolderStore.shared.folders(kind: .library)
        async let temporaries = RegisteredFolderStore.shared.folders(kind: .temporary)
        library = await Self.entries(for: libraries)
        temporary = await Self.entries(for: temporaries)
    }

    private static func entries(for folders: [RegisteredFolder]) async -> [Entry] {
        var result: [Entry] = []
        for folder in folders {
            guard let url = await RegisteredFolderStore.shared.resolvedURL(for: folder) else { continue }
            result.append(Entry(
                id: folder.id,
                displayName: folder.displayName,
                url: url,
                thumbnailsAlwaysHidden: folder.hidesThumbnails
            ))
        }
        return result
    }
}
