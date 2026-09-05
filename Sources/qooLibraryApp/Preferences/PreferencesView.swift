import SwiftUI

/// 環境設定ウインドウのルート [15.10 節、1-12]。`qooLibraryApp.swift` の
/// `Window(id: "preferences")` シーンから開く（`⌘,` は
/// `PreferencesMenuButton` が手動配線する）。
///
/// 仕様書 §15.10 は8タブ（一般/表示/キーボード/関連付け/スキャン/キャッシュ/
/// データ/通知/詳細）を定義しているが、関連付け・スキャン・データ・通知・
/// 詳細の大半は `AppAssociationService`/`ScanEngine`/`NotificationHistoryStore`/
/// 診断ログ基盤（当時いずれも未実装）に依存するため、実際に意味を持つ
/// カテゴリのみを実装する [設計判断、CLAUDE.md 1-12 節参照]。
/// **「リセット」タブはフェーズ 2 の DB が入った時点で中身が付いた**
/// （`ResetPreferencesTab`）。
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
                case .scan: ScanPreferencesTab()
                case .cache: CachePreferencesTab()
                case .notifications: NotificationPreferencesTab()
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
    /// [15.10 節、2-2] 取りこぼしへの備え [SY-05][VD-09]。`ScanPreferencesTab` 参照。
    case scan
    case cache
    /// [15.10 節、NT-07] 通知履歴の保持期間・上限。`NotificationPreferencesTab` 参照。
    /// **システム通知 [ER-33] はまだ置いていない**（ER-30〜34 が未実装）。
    case notifications
    /// [15.10 節、1-15] 診断ログ [LG2-01〜LG2-08]。`AdvancedPreferencesTab` 参照。
    case advanced
    /// 一番下に置く [ユーザー要望]。ライブラリ単位の削除・JSON の書き出しと
    /// 取り込み・サムネイルの一括削除を扱う（`ResetPreferencesTab` 参照）。
    ///
    /// **「エクスポート/インポートを先に実装してから削除を出す」という制約**
    /// ［ユーザーからの明示的な制約］は満たしている——同じタブの上段に
    /// 書き出しと取り込みがあり、順序そのものが案内になっている。
    /// **DB 全体を一度に消すボタンはまだ無い**。追加するなら、まず
    /// 2-16 の本番（世代管理・復元 UI [BK-01〜BK-04]）を済ませること。
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
        case .scan: "preferences.tab.scan"
        case .cache: "preferences.tab.cache"
        case .notifications: "preferences.tab.notifications"
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
        case .scan: "arrow.triangle.2.circlepath"
        case .cache: "internaldrive"
        // 通知履歴と操作履歴の両方を持つので、鐘ではなく時計
        // （鍵と型名は据え置き。詳細は `NotificationPreferencesTab` の doc）。
        case .notifications: "clock"
        case .advanced: "wrench.and.screwdriver"
        case .reset: "arrow.counterclockwise.circle"
        }
    }
}
