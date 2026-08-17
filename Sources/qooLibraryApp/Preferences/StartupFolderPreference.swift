import Foundation
import QooInfrastructure

/// アプリ起動時に開くフォルダの選択 [ユーザー要望、環境設定「一般」タブ]。
///
/// **テンポラリ／ライブラリフォルダ（登録フォルダ）と、通常のボリューム上の
/// 任意フォルダを区別して保存する**［ユーザー指摘: 「テンポラリフォルダと
/// ライブラリフォルダは、通常のボリューム上のフォルダとは分けて設定できる
/// こと」］。登録フォルダは ID で参照するため、後から表示名を変更しても
/// 追従する。ボリューム上の任意フォルダは専用の Security-Scoped Bookmark
/// （`RegisteredFolderStore` とは別の、この設定専用のもの）で参照する。
enum StartupFolderKind: String {
    /// ホーム（既定）。**`rawValue` が `"virtualHome"` なのは歴史的な事情**で、
    /// 既に永続化されている設定値を壊さないためそのまま残している。実際の
    /// 行き先は実ホーム（読めなければ仮想ホーム）で、`StandardLocation.defaultHome`
    /// が決める［ユーザー判断、1-16 移動メニューの Finder 準拠］。
    case home = "virtualHome"
    case registeredFolder
    case volumeFolder
}

enum StartupFolderPreference {
    static let kindKey = "qoo.preferences.startupFolder.kind"
    static let registeredFolderIDKey = "qoo.preferences.startupFolder.registeredFolderID"
    /// 選択した登録フォルダがテンポラリ／ライブラリのどちらのリストに属して
    /// いたかを覚えておく（`RegisteredFolderKind.rawValue`）。環境設定 UI が
    /// 「現在の選択モード」を同期的に判定できるようにするため
    /// （`temporaryFolders`/`libraryFolders` の非同期読み込み完了を待たずに
    /// 初期表示を決められる）。
    static let registeredFolderCategoryKey = "qoo.preferences.startupFolder.registeredFolderCategory"
    static let volumeBookmarkKey = "qoo.preferences.startupFolder.volumeBookmark"
    static let volumeDisplayNameKey = "qoo.preferences.startupFolder.volumeDisplayName"

    /// 起動時に実際に開くフォルダを解決する [`MainWindowView` から、アプリ
    /// 起動直後の最初のウインドウにだけ適用する]。`registeredFolder` は
    /// `RegisteredFolderStore` の解決を要するため非同期。登録解除済み・
    /// ボリューム未接続等で解決できない場合はホームへフォールバックする。
    @MainActor
    static func resolve() async -> (url: URL, navigationRoot: NavigationRoot) {
        // **先にボリューム許可を有効化しておく**［1-16 移動メニューの Finder
        // 準拠でホームを実ホームへ移したときに必要になった］。`defaultHome` は
        // 「実ホームが読めるか」で行き先を決めるが、`qooLibraryApp.init()` が
        // 起動する `loadAndActivateAll()` は非同期なので、待たずに判定すると
        // まだ許可が有効になっておらず**毎回仮想ホームへ落ちてしまう**。
        // `ensureLoaded()` でメモ化されているため二重読み込みにはならない。
        await VolumeAccessStore.shared.loadAndActivateAll()

        let defaults = UserDefaults.standard
        let kind = defaults.string(forKey: kindKey).flatMap(StartupFolderKind.init(rawValue:)) ?? .home

        switch kind {
        case .home:
            return (StandardLocation.defaultHome, .volume)

        case .registeredFolder:
            guard let idString = defaults.string(forKey: registeredFolderIDKey), let id = UUID(uuidString: idString) else {
                return (StandardLocation.defaultHome, .volume)
            }
            // **こちらにも上限が要る** [NV-91]。`RegisteredFolderStore` は
            // `actor` で、その中のブックマーク解決は `FileIO` を経由して
            // いない（8章 §8.11.17 の NV6-05、未対処）。応答しない共有では
            // ここで待ち続け、**起動直後のウインドウが出てこない**。
            //
            // 待つのをやめても actor 自体の詰まりは解けない [NV6-03] が、
            // **起動だけは先へ進める**。ホームで開いてしまうほうが、
            // 何も出ないよりはるかにましである。
            let found = try? await FileIO.withDeadline(.seconds(5)) {
                // **状態を見る** [1-17]。以前は解決できさえすれば開いていたため、
                // 起動時フォルダに指定したライブラリをゴミ箱へ入れると
                // **毎回ゴミ箱の中を開いた状態で起動していた**（ブックマークは
                // inode を追跡するので解決には成功する [BM-2]）。入って
                // 辿れない状態ならホームへ落とすほうがよい。
                let states = await RegisteredFolderStore.shared.states()
                guard let state = states.first(where: { $0.folder.id == id }),
                      state.status.allowsNavigation,
                      let url = state.status.resolvedURL
                else { return URL?.none }
                return url
            }
            guard let url = found ?? nil else {
                return (StandardLocation.defaultHome, .volume)
            }
            return (url, .registeredFolder(id: id, rootURL: url))

        case .volumeFolder:
            guard let data = defaults.data(forKey: volumeBookmarkKey) else {
                return (StandardLocation.defaultHome, .volume)
            }
            // **メインアクタで解決してはいけない** [NV6-02]。`.withoutMounting`
            // を付けてもブックマークの解決は対象を確かめるためにファイル
            // システムへ出るので、相手が**マウント済みなのに応答しない**
            // 共有だと、ここでメインスレッドが止まる——つまり
            // **起動直後のウインドウが出てこない**。
            //
            // 上限も付ける [NV-91]。起動は人が待っている場面なので、
            // 応答しない相手のために待ち続けるより、既定（ホーム）で
            // 開いてしまうほうがはるかにましである。
            let resolved: URL? = try? await FileIO.perform(waitingAtMost: .seconds(5)) {
                guard case .resolved(let url, _) = SecurityScopedBookmarkResolver().resolve(data) else {
                    return URL?.none
                }
                return url
            }
            guard let resolved = resolved ?? nil else {
                return (StandardLocation.defaultHome, .volume)
            }
            // **アクセスの開始は上限の外側で行う。** 中でやると、期限切れで
            // 結果を捨てたあとにもクロージャは走り続けるので、**誰も保持して
            // いない URL のセキュリティスコープが開きっぱなしになる**
            // （レビューで指摘された）。ここなら「使う URL」と 1 対 1 で対応する。
            //
            // 登録フォルダと同じ方針: 個々の読み取りのたびに start/stop せず、
            // アプリ終了までアクセスを開始したままにする [1-2 のパターン]。
            _ = resolved.startAccessingSecurityScopedResource()
            return (resolved, .volume)
        }
    }
}
