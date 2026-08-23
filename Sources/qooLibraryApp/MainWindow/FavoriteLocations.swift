import Foundation
import QooInfrastructure

/// 左ペイン「よく使う項目」グループの 1 行分の材料 [ユーザー要望: Finder に
/// 似せて 1 つのグループにまとめ、表示する項目を環境設定から選べるようにする]。
///
/// **どの場所かを `StandardLocation` として持ち続けるのが要点。** 表示名も
/// アクセス要件も「移動」メニューと同じ 1 つの型が持っているので、ツリーと
/// メニューで訳語や許可の求め方が食い違わない。
struct FavoriteItem: Identifiable, Sendable {
    let location: StandardLocation
    let node: FolderTreeNode

    var id: String { node.id }
}

/// 「よく使う項目」に並べられる場所と、そのうち実際に表示するものの管理
/// [ユーザー要望]。
///
/// **ここが唯一の出どころ。** 何を並べられるか（`candidates`）・既定で何を
/// 出すか（`defaultVisible`）・いま何が出ているか（`visible`）を 1 か所に
/// 集める——2 か所に分けると、環境設定で選べる項目とツリーに出る項目が
/// 食い違う。
enum FavoriteLocations {
    /// 表示できる場所と、その並び順 [ユーザー指定]。
    ///
    /// 並べ替えは提供しない（表示・非表示だけ）。順序をここで固定しておけば、
    /// どの項目を出しても位置関係が変わらず、覚えた位置で押せる。
    static let candidates: [StandardLocation] = [
        .applications, .home, .desktop, .documents, .downloads, .movies, .music, .pictures,
    ]

    /// 何も設定していないときに出るもの [ユーザー指定]。
    static let defaultVisible: Set<StandardLocation> = [.applications, .home, .desktop, .downloads]

    static func storageKey(_ location: StandardLocation) -> String {
        "qoo.favorites.visible.\(location.rawValue)"
    }

    /// **項目ごとに 1 つのキー**で持つ。配列で持つと「まだ設定していない」と
    /// 「全部消した」の区別が付かず、後から候補を増やしたときに既存の利用者へ
    /// 出すかどうかも決められない（`AppAssociationStore` が同じ形で移行を
    /// 要したのと同じ問題）。
    static func isVisible(_ location: StandardLocation) -> Bool {
        guard candidates.contains(location) else { return false }
        let key = storageKey(location)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultVisible.contains(location)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setVisible(_ location: StandardLocation, _ visible: Bool) {
        guard candidates.contains(location) else { return }
        UserDefaults.standard.set(visible, forKey: storageKey(location))
    }

    /// いま表示する場所（`candidates` の順）。
    static var visible: [StandardLocation] { candidates.filter(isVisible) }

    /// 表示設定を既定へ戻す [環境設定「表示」タブの「既定に戻す」]。
    static func resetToDefaults() {
        for location in candidates {
            UserDefaults.standard.removeObject(forKey: storageKey(location))
        }
    }

    // MARK: - ツリーの行を作る

    /// 並べる行を作る。**存在しないフォルダは落とす**——`~/Movies` のように
    /// 消されていることがあり（[実測] `~/Sites` は既定では作られない）、
    /// 開けない行を出しても意味が無い。
    ///
    /// **アクセス権の有無では落とさない。** 未許可でも `fileExists`・表示名・
    /// アイコンはすべて正しく取れる [実測] ので、行は普通に並べ、押されたときに
    /// 許可を求める［ユーザー判断］。そうしないと、許可を与えるための入口
    /// 自体が無くなってしまう。
    ///
    /// **メインアクタの外で走る。** `FileIO.perform` の中からのみ呼ぶこと
    /// [NV6-02]——`fileExists` も `DirectoryProbe` も実 I/O である。
    nonisolated static func load(_ locations: [StandardLocation]) -> [FavoriteItem] {
        locations.compactMap { location in
            let url = location.url
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return FavoriteItem(
                location: location,
                node: FolderTreeNode(
                    url: url,
                    kind: .favorite,
                    // 三角の出し分け [`FolderTreeNode.hasSubfolders`]。読めない
                    // フォルダ（未許可）では `nil` が返り、三角は出たままに
                    // なる——押せば許可を求められるので、そのほうが行き止まりに
                    // ならない。ツリーはパッケージを出さないので数にも入れない
                    // （`/Applications` は 45 件中 41 件がパッケージ [実測]）。
                    hasSubfolders: DirectoryProbe.hasSubdirectory(at: url, countingPackages: false)
                )
            )
        }
    }

    /// `url` を含む行のうち**一番深いもの**。含む行が無ければ `nil`。
    ///
    /// ツリーの自動展開でどこまで遡るかを決める [`FolderTreePane`]。
    /// `~/Downloads/foo` はホーム行にも「ダウンロード」行にも一致するが、
    /// 開きたいのは後者の下だけ——上まで開くと、同じフォルダがホーム行の下と
    /// ダウンロード行の下の 2 か所に見えることになる。
    ///
    /// **成分の境界で照合する。** 素の `hasPrefix` だと `~/Doc` が
    /// `~/Documents` を覆う（`VolumeAccessStore.hasGrant` で同じ判定を
    /// 書いたときに踏んだ形）。
    ///
    /// - Note: 純粋関数にしてあるのは、この手の最長一致・打ち切り判定で
    ///   このコードベースが繰り返しバグを踏んでいるため（`ancestorPaths` の
    ///   `floor` 判定で 2 回、ボリュームのマウントポイントで 1 回）。
    ///   引数だけで振る舞いが決まる形なら、実アプリを起動しなくても確かめられる。
    static func root(containing url: URL, in roots: [URL]) -> URL? {
        let path = url.standardizedFileURL.path
        return roots
            .filter { root in
                let rootPath = root.standardizedFileURL.path
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    /// いま表示している場所のうち、`url` を含む一番深いもの
    /// [`WindowState.normalizedRoot` と `FolderTreePane` が使う]。
    static func containingVisibleRoot(of url: URL) -> URL? {
        root(containing: url, in: visible.map(\.url))
    }
}
