import SwiftUI

/// 環境設定ウインドウのルート [15.10 節、1-12]。`qooLibraryApp.swift` の
/// `Window(id: "preferences")` シーンから開く（`⌘,` は
/// `PreferencesMenuButton` が手動配線する）。
///
/// 仕様書 §15.10 は8タブ（一般/表示/キーボード/関連付け/スキャン/キャッシュ/
/// データ/通知/詳細）を定義しているが、関連付け・スキャン・データ・通知・
/// 詳細の大半は `AppAssociationService`/`ScanEngine`/SwiftData/
/// `NotificationHistoryStore`/診断ログ基盤（いずれも未実装）に依存するため、
/// 現在のアーキテクチャで実際に意味を持つカテゴリ（一般/表示/キーボード/
/// キャッシュ）のみを実装する [設計判断、CLAUDE.md 1-12 節参照]。
/// **「圧縮／展開」タブ**は仕様書 §15.10 の定義には無い、ユーザー要望による
/// 追加（`CompressionPreferencesTab` 参照）。
///
/// **`TabView`（タブバー方式）ではなく `NavigationSplitView`（左サイドバー＋
/// 右詳細ペインの2ペイン構成）を使う** [ユーザー要望: 最近の macOS システム
/// 設定と同じ構成にしたい。「タブ方式だと気軽に増やしにくい」との指摘で、
/// カテゴリを増やすたびにタブバーの横幅を圧迫するタブ方式から、縦方向に
/// 積み増せるサイドバー方式へ変更した]。`MainWindowView` と同じ
/// `NavigationSplitView` を再利用する設計判断。
///
/// **カテゴリ名タイトルはウインドウ中央ではなく `.navigationTitle`（サイドバー
/// 境界に追従して左寄りになる）を使っている** [実機検証で判明した既知の妥協]。
/// 当初はウインドウ中央に来る `.principal` 配置のツールバー項目を試したが、
/// macOS 26 の `NavigationSplitView` では `.principal` 項目が「現在のタブ」を
/// 示すピル（カプセル）状の背景付きで自動描画される（`Settings` シーン固有の
/// 挙動かと思い `Window(id:)` へ切り替えて検証したが、`Settings` 固有ではなく
/// `NavigationSplitView` 自体の挙動だと判明した）。SwiftUI の公開 API で
/// このピルを取り除く方法が見つからず、ユーザー判断で「タイトルが左に寄る
/// 程度は許容し、ピルが出ない `.navigationTitle` を使う」ことに決定した。
struct PreferencesView: View {
    @State private var selection: PreferencesCategory? = .general

    var body: some View {
        content
            // フォルダツリーの「アクセスを許可…」等、ウインドウの外から特定の
            // カテゴリを開いてほしいという要求を受け取る [ユーザー要望:
            // 「ボリュームの『アクセスを許可』ボタンをクリックしたら、環境設定の
            // アクセス権タブが開くようにできますか？」]。ウインドウが未作成
            // （初回オープン）・既存ウインドウの再利用（既に開いていて前面に
            // 来るだけ）のどちらでも反映されるよう、初回表示 `.task` と、
            // 表示中の変化を拾う `.onChange` の両方で見る。
            .task {
                applyPendingCategoryIfNeeded()
            }
            .onChange(of: PreferencesNavigation.shared.pendingCategory) {
                applyPendingCategoryIfNeeded()
            }
    }

    private func applyPendingCategoryIfNeeded() {
        guard let pending = PreferencesNavigation.shared.pendingCategory else { return }
        selection = pending
        PreferencesNavigation.shared.pendingCategory = nil
    }

    private var content: some View {
        // `columnVisibility: .constant(.all)` で常に両カラムを表示したまま
        // 固定する。macOS システム設定と同じく、サイドバーの表示/非表示を
        // 切り替えるトグルボタン自体を無くしたい [ユーザー要望]。
        // `NavigationSplitView` は既定でこのボタンをツールバーへ自動的に
        // 追加するが、`.toolbar(removing: .sidebarToggle)` は
        // `NavigationSplitView` 自体ではなく**サイドバー側のコンテンツ
        // （`List`）に付けないと効かない**ことが実機検証で判明した
        // （`NavigationSplitView` 直下に付けても消えなかった）。
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(PreferencesCategory.allCases, selection: $selection) { category in
                Label(category.titleKey, systemImage: category.systemImage)
                    // [ユーザー指摘の修正] `QooLibraryApp.init()` で登録した
                    // `NSTableViewDefaultSizeMode`（フォルダツリーの行間を
                    // 詰めるための設定）はアプリ全体の `.sidebar` スタイル
                    // リストに影響するため、この環境設定サイドバーの文字も
                    // 一緒に縮んでしまっていた。`FolderTreePane` と同じく
                    // 明示的にサイズを指定して切り離す。
                    .font(.system(size: Tokens.fontSize.body))
                    .tag(category)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPreferencesTab()
                case .display: DisplayPreferencesTab()
                case .keyboard: KeyboardPreferencesTab()
                case .associations: AssociationPreferencesTab()
                case .compression: CompressionPreferencesTab()
                case .access: AccessPreferencesTab()
                case .cache: CachePreferencesTab()
                case .advanced: AdvancedPreferencesTab()
                case .reset: ResetPreferencesTab()
                case nil: EmptyView()
                }
            }
            .navigationTitle(selection.map { Text($0.titleKey) } ?? Text(""))
        }
        .frame(width: 620, height: 420)
    }
}

/// ウインドウの外（フォルダツリーの「アクセスを許可…」等）から、環境設定の
/// 特定カテゴリを開いてほしいという要求を仲介する [ユーザー要望]。
/// `PreferencesView` は `@Observable` の変化を `.onChange`/`.task` で監視し、
/// 検出したら自身の `selection` に反映してこの値をクリアする。
@MainActor
@Observable
final class PreferencesNavigation {
    static let shared = PreferencesNavigation()
    private init() {}

    var pendingCategory: PreferencesCategory?
}

/// 環境設定のカテゴリ一覧 [設計判断、上記型コメント参照]。
enum PreferencesCategory: CaseIterable, Identifiable {
    case general
    case display
    case keyboard
    /// [12章 §12.9、AS-01〜AS-07 の実装可能な範囲] `AssociationPreferencesTab` 参照。
    case associations
    /// [ユーザー要望、要件定義書には無い] `CompressionPreferencesTab` 参照。
    case compression
    /// [ユーザー要望、要件定義書には無い] `AccessPreferencesTab` 参照。
    /// フルディスクアクセスがサンドボックスの制限を回避しないと判明した
    /// ことを受けての代替手段。
    case access
    case cache
    /// [15.10 節、1-15] 診断ログ [LG2-01〜LG2-08]。`AdvancedPreferencesTab` 参照。
    case advanced
    /// 一番下に置く [ユーザー要望、CLAUDE.md「将来検討」参照]。データベース
    /// （SwiftData、Phase 2）がまだ無いため現状はプレースホルダのみで、
    /// 一括削除ボタン自体はまだ実装しない。**エクスポート/インポート機能を
    /// 先に実装してからでないと一括削除ボタンを追加してはならない**
    /// [ユーザーからの明示的な制約]。
    case reset

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "preferences.tab.general"
        case .display: "preferences.tab.display"
        case .keyboard: "preferences.tab.keyboard"
        case .associations: "preferences.tab.associations"
        case .compression: "preferences.tab.compression"
        case .access: "preferences.tab.access"
        case .cache: "preferences.tab.cache"
        case .advanced: "preferences.tab.advanced"
        case .reset: "preferences.tab.reset"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .display: "eye"
        case .keyboard: "keyboard"
        case .associations: "app.badge"
        case .compression: "archivebox"
        case .access: "lock.open"
        case .cache: "internaldrive"
        case .advanced: "wrench.and.screwdriver"
        case .reset: "arrow.counterclockwise.circle"
        }
    }
}
