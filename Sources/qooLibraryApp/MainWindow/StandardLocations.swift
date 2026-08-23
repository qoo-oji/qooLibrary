import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// Finder の「移動」メニューが並べる標準の場所 [1-16 移動メニューの Finder
/// 準拠、ユーザー要望「移動メニューの表示内容（アイコン含む）および機能を
/// Finder に揃える」]。
///
/// **Finder にあってここに無いもの**と、その理由:
///
/// | Finder | 理由 |
/// |---|---|
/// | 最近の項目（⇧⌘F） | Spotlight（`NSMetadataQuery`）を要する別機能 |
/// | AirDrop（⇧⌘R） | 公開 API が無い。アイコン `airdrop` も非公開シンボル |
/// | ネットワーク（⇧⌘K） | `/Network` のブラウズは Finder 専用。加えて ⇧⌘K は `clearLabelFilter` [LF-07] と衝突する |
/// | クラウドストレージ（⌥⇧⌘I） | `~/Library/CloudStorage`。この機に第三者クラウドが 1 つも無く検証できないため見送り [NV8-04 と同じ理由] |
/// | iCloud Drive - Enterprise（⌃⇧⌘I） | 該当環境が無い |
enum StandardLocation: String, CaseIterable, Identifiable, Sendable {
    case home
    case documents
    case desktop
    case downloads
    // ここから 3 つは **Finder の「移動」メニューには無い**（Finder も出して
    // いない）。フォルダツリーの「ホーム」グループにだけ並べる [ユーザー要望:
    // 「ボリュームとテンポラリの間にホームグループを追加し、ユーザーフォルダの
    // ダウンロードなどにアクセスできるように」]。`action` を持たないのはその
    // ため——キーを割り当てないものを `DefaultKeyBindings` に載せると、
    // 環境設定「キーボード」タブに何も起きない項目が並ぶ。
    case movies
    case music
    case pictures
    case library
    case computer
    case iCloudDrive
    case shared
    case applications
    case utilities

    var id: String { rawValue }

    // MARK: - 実ホーム

    /// **サンドボックス下でも実ホームを返す** [実測で確認]。
    ///
    /// `FileManager.homeDirectoryForCurrentUser` / `NSHomeDirectory()` は
    /// サンドボックスではコンテナ（`~/Library/Containers/<bundle-id>/Data`）を
    /// 返すが、`getpwuid(getuid())->pw_dir` は実ホーム（`/Users/<name>`）を
    /// 返す——実アプリと同じ entitlement でアドホック署名した最小アプリで
    /// 実測済み。
    static let realHome: URL = {
        if let pw = getpwuid(getuid()) {
            let path = String(cString: pw.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// サンドボックスの仮想ホーム。実ホームが読めないときの避難先。
    static var virtualHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 起動時・⌘T の行き先 [ユーザー判断: 「ホーム」は実ホームに統一する]。
    ///
    /// **実ホームが読めないときだけ仮想ホームへ落とす。** 何も許可していない
    /// 初回起動でいきなりエラー画面になるのを避けるためで、許可さえすれば
    /// 以降は実ホームが出る。判定は `access(2)` 1 回（起動ボリューム上の
    /// ローカル I/O でマイクロ秒。NV6-02 が防ぎたい「相手待ちが青天井になる
    /// I/O」には当たらない）。
    ///
    /// **毎回評価する**（`static let` でキャッシュしない）。起動直後は
    /// `VolumeAccessStore.loadAndActivateAll()` がまだ終わっていないことが
    /// あり、そこで一度 `false` を掴むとプロセスが終わるまで仮想ホームに
    /// 張り付いてしまうため。
    static var defaultHome: URL {
        let real = realHome
        return access(real.path, R_OK) == 0 ? real : virtualHome
    }

    /// 「ホーム」を開くときの行き先と入口。**解決できないときのフォール
    /// バック先でもある**［ユーザー判断: アクセスできない場合はボリューム
    /// 経由でホームフォルダに落ちてよい］。
    ///
    /// 入口は `StandardLocation.home.navigationRoot` に委ねる——「よく使う
    /// 項目」にホームを表示していれば `.favorites`（その行がフォーカスされる）、
    /// 隠していれば `.volume`（ボリュームツリーを辿ってフォーカスされる）。
    /// **仮想ホームへ落ちたときは必ず `.volume`**: 仮想ホームはどの行にも
    /// 対応しないので、`.favorites` を名乗ると宙に浮く。
    ///
    /// ⌘T・タブバーの ＋・起動時フォルダ・解決に失敗したときのフォールバック
    /// が**すべてここを通る**——「ホームを開く」の意味が経路ごとに違わない
    /// ようにするため。
    static var homeDestination: (url: URL, navigationRoot: NavigationRoot) {
        let url = defaultHome
        let isRealHome = url.standardizedFileURL == realHome.standardizedFileURL
        return (url, isRealHome ? StandardLocation.home.navigationRoot : .volume)
    }

    // MARK: - 各項目

    var url: URL {
        let home = Self.realHome
        switch self {
        case .home: return home
        case .documents: return home.appendingPathComponent("Documents", isDirectory: true)
        case .desktop: return home.appendingPathComponent("Desktop", isDirectory: true)
        case .downloads: return home.appendingPathComponent("Downloads", isDirectory: true)
        case .movies: return home.appendingPathComponent("Movies", isDirectory: true)
        case .music: return home.appendingPathComponent("Music", isDirectory: true)
        case .pictures: return home.appendingPathComponent("Pictures", isDirectory: true)
        case .library: return home.appendingPathComponent("Library", isDirectory: true)
        // Finder の「コンピュータ」はマウント中のボリュームと起動ディスクを
        // 束ねた合成ビューで、そのまま再現できる公開 API は無い。実体として
        // 一番近い `/Volumes` で近似する [ユーザー判断で採用]。
        case .computer: return URL(fileURLWithPath: "/Volumes", isDirectory: true)
        case .iCloudDrive:
            return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        case .shared: return URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        case .applications: return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .utilities: return URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .home: return "menu.go.home"
        case .documents: return "menu.go.documents"
        case .desktop: return "menu.go.desktop"
        case .downloads: return "menu.go.downloads"
        case .movies: return "menu.go.movies"
        case .music: return "menu.go.music"
        case .pictures: return "menu.go.pictures"
        case .library: return "menu.go.library"
        case .computer: return "menu.go.computer"
        case .iCloudDrive: return "menu.go.iCloudDrive"
        case .shared: return "menu.go.shared"
        case .applications: return "menu.go.applications"
        case .utilities: return "menu.go.utilities"
        }
    }

    /// Finder の `MenuBar.nib` から読み出した SF Symbol をそのまま使う
    /// [1-16 のアイコン監査と同じ手法]。
    ///
    /// **`appstore`（Finder の「アプリケーション」）だけは非公開シンボルで
    /// `NSImage(systemSymbolName:)` が `nil` を返す**（`square.dashed.and.alias`
    /// と同じ罠。実在を確かめてから使うこと）ため代替に置き換えている。
    /// 「コンピュータ」は Finder 自身がアイコンを持たないが、他が全部持って
    /// いる中で 1 つだけ空くと収まりが悪いので実体（`/Volumes`）に合うものを
    /// 選んだ。
    var systemImage: String {
        switch self {
        case .home: return "house"
        case .documents: return "document"
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.circle"
        // この 3 つは Finder のメニューに対応する項目が無いので、シンボルは
        // 実フォルダのアイコンの意匠に合わせて選んだ。**ツリーの行が実際に
        // 描くのは `FileIconProvider`（Finder とまったく同じアイコン）**で、
        // ここは移動メニューのような SF Symbol を要する場所のための保険。
        case .movies: return "film"
        case .music: return "music.note"
        case .pictures: return "photo"
        case .library: return "building.columns"
        case .computer: return "internaldrive"
        case .iCloudDrive: return "icloud"
        case .shared: return "folder.badge.person.crop"
        case .applications: return "square.grid.2x2"
        case .utilities: return "wrench.and.screwdriver"
        }
    }

    /// Finder と同じキー。`isCustomizable: false` で登録するので、メニューに
    /// そのまま表示される（`KeyBinding.isCustomizable` のコメント参照）。
    ///
    /// **移動メニューに出さない項目は `nil`。** Finder に対応するコマンドが
    /// 無いものへ独自のキーを割り当てると、Finder 準拠という基準を自分で崩す
    /// うえ、環境設定「キーボード」タブに実体の無い項目が並ぶ。
    var action: ActionID? {
        switch self {
        case .movies, .music, .pictures: return nil
        case .home: return .goToHome
        case .documents: return .goToDocuments
        case .desktop: return .goToDesktop
        case .downloads: return .goToDownloads
        case .library: return .goToLibrary
        case .computer: return .goToComputer
        case .iCloudDrive: return .goToICloudDrive
        case .shared: return .goToShared
        case .applications: return .goToApplications
        case .utilities: return .goToUtilities
        }
    }

    /// Finder は「ライブラリ」を ⌥ 代替（⇧⌘L）として隠している。同じにする。
    var isOptionAlternate: Bool { self == .library }

    // MARK: - フォルダツリーの「よく使う項目」グループ

    /// この場所へ移動したとき、タブがどの入口から来たことにするか
    /// [`NavigationRoot` 参照]。
    ///
    /// **「よく使う項目」に*表示されている*場所だけが `.favorites`。**
    /// 表示していない場所を `.favorites` で開くと、対応する行が無いのに
    /// その入口を名乗ることになり、ツリーは何も指せないまま「1 階層上へ」の
    /// 境界だけが効く、という説明できない状態になる。
    ///
    /// これで移動メニューから「ダウンロード」を選んでも、ツリーの
    /// 「よく使う項目」側がフォーカスされる——**同じ場所へ行く経路が複数
    /// あっても、行き先の見え方は 1 つに揃える。**
    var navigationRoot: NavigationRoot {
        FavoriteLocations.isVisible(self) ? .favorites : .volume
    }

    // MARK: - アクセス要件

    /// その場所へ届くために何が要るか。**すべて実測に基づく**——根拠と測定
    /// 結果の表は `qooLibrary.entitlements` のコメントにある。
    enum AccessRequirement: Sendable {
        /// 素のサンドボックスで読める。何も要らない。
        case none
        /// entitlement で読める。ユーザーの操作は要らない。
        case entitlement
        /// 自身または祖先への許可（`VolumeAccessStore`）が要る。
        /// `/` を許可してあれば足りる。
        case grantOfSelfOrAncestor
        /// **その場所そのもの**への許可が要る。TCC 保護フォルダで、祖先
        /// （`/` や実ホーム）への許可ではサンドボックス層しか通らず、TCC が
        /// 毎回ダイアログを出す。
        case grantOfExactPath
    }

    var accessRequirement: AccessRequirement {
        switch self {
        // `/Applications` は素のサンドボックスで読める [実測]。「よく使う項目」
        // に既定で出るのはこのため——許可を求めずに使える。
        case .applications, .utilities, .computer: return .none
        // `~/Movies` / `~/Music` / `~/Pictures` は `com.apple.security.assets.*`
        // で素通りする [実測、`qooLibrary.entitlements` の表]。**許可を求めずに
        // 開ける**ので、ホームグループでは押した瞬間に中身が出る。
        case .downloads, .movies, .music, .pictures: return .entitlement
        case .documents, .desktop: return .grantOfExactPath
        case .home, .library, .shared, .iCloudDrive: return .grantOfSelfOrAncestor
        }
    }
}

/// 標準の場所を開く（必要なら 1 回だけ許可を求める）[ユーザー判断:
/// 「未許可ならその場でパネルを出す」]。
///
/// フォルダツリーの `AccessDeniedRow` は環境設定「アクセス権」タブへ**誘導**
/// するのに対し、ここは**その場で**パネルを出す。あちらは「アクセス権が
/// ありません」という状態表示に添えたボタンなのに対し、こちらは「書類へ
/// 行きたい」という明示的な要求の直後だからで、環境設定が開くのは遠回りに
/// なる。許可した結果はどちらも `VolumeAccessStore` に入り「アクセス権」タブ
/// に現れるので、一元管理は保たれる。
@MainActor
enum StandardLocationOpener {
    /// - Parameter onCancel: 許可パネルをユーザーが閉じたときに呼ぶ。
    ///   フォルダツリーはここで**行の選択を元に戻す**必要がある——`List` の
    ///   選択は押した瞬間に動いてしまうので、移動しなかったのに選択だけが
    ///   進んだ状態が残ると、次に ↑ ↓ を押したとき居ない場所から動き出す。
    ///   メニューから呼ぶ場合は選択の概念が無いので既定の空実装でよい。
    static func open(
        _ location: StandardLocation,
        locale: Locale,
        onCancel: @escaping () -> Void = {},
        navigate: @escaping (URL) -> Void
    ) {
        let url = location.url
        switch location.accessRequirement {
        case .none, .entitlement:
            navigate(url)
        case .grantOfSelfOrAncestor, .grantOfExactPath:
            let exact = location.accessRequirement == .grantOfExactPath
            Task {
                if await VolumeAccessStore.shared.hasGrant(covering: url, requiringExactMatch: exact) {
                    navigate(url)
                    return
                }
                guard await requestAccess(to: url, locale: locale) else {
                    onCancel()
                    return
                }
                navigate(url)
            }
        }
    }

    /// パネルを出して許可を得る。ユーザーが取り消したら `false`。
    ///
    /// パネルは対象フォルダを指した状態で開くので、そのまま「開く」を押すだけ
    /// で済む（環境設定「アクセス権」タブが `/` を既定で指すのと同じ考え方）。
    ///
    /// **移動メニュー以外からも呼ぶ**: 中央ペインが読み込みに失敗したときの
    /// 「アクセスを許可…」も同じ経路を通る（`FolderContentView`）。移動メニューを
    /// 経由しない到達（ツリーのクリック・ダブルクリックで潜る等）はここの
    /// 事前判定が働かないため、実際に失敗した側からも同じ導線を出せるようにする。
    static func requestAccess(to url: URL, locale: Locale) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.message = String(localized: "access.grantPanelMessage", locale: locale)
        panel.prompt = String(localized: "access.grantPanelPrompt", locale: locale)
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        do {
            _ = try await VolumeAccessStore.shared.grantAccess(to: chosen, displayName: nil)
            // 「アクセス権がありません」をキャッシュしているフォルダツリーの行を
            // 読み直させる（`AccessPreferencesTab.addAccess()` と同じ理由）。
            SessionState.shared.reloadToken += 1
            return true
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.operationFailed", locale: locale)
            )
            return false
        }
    }
}
