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
    case virtualHome
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
    /// ボリューム未接続等で解決できない場合は仮想ホームへフォールバックする。
    @MainActor
    static func resolve() async -> (url: URL, navigationRoot: NavigationRoot) {
        let defaults = UserDefaults.standard
        let kind = defaults.string(forKey: kindKey).flatMap(StartupFolderKind.init(rawValue:)) ?? .virtualHome

        switch kind {
        case .virtualHome:
            return (FileManager.default.homeDirectoryForCurrentUser, .volume)

        case .registeredFolder:
            guard let idString = defaults.string(forKey: registeredFolderIDKey), let id = UUID(uuidString: idString) else {
                return (FileManager.default.homeDirectoryForCurrentUser, .volume)
            }
            for folderKind in [RegisteredFolderKind.library, .temporary] {
                let folders = await RegisteredFolderStore.shared.folders(kind: folderKind)
                guard let folder = folders.first(where: { $0.id == id }),
                      let url = await RegisteredFolderStore.shared.resolvedURL(for: folder)
                else { continue }
                return (url, .registeredFolder(id: id, rootURL: url))
            }
            return (FileManager.default.homeDirectoryForCurrentUser, .volume)

        case .volumeFolder:
            guard let data = defaults.data(forKey: volumeBookmarkKey) else {
                return (FileManager.default.homeDirectoryForCurrentUser, .volume)
            }
            guard case .resolved(let url, _) = SecurityScopedBookmarkResolver().resolve(data) else {
                return (FileManager.default.homeDirectoryForCurrentUser, .volume)
            }
            // 登録フォルダと同じ方針: 個々の読み取りのたびに start/stop せず、
            // アプリ終了までアクセスを開始したままにする [1-2 のパターン]。
            _ = url.startAccessingSecurityScopedResource()
            return (url, .volume)
        }
    }
}
