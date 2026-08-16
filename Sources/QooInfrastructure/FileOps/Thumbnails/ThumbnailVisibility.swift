import Foundation
import Observation

/// サムネイル・カバー画像を表示するかどうかの**アプリ全体の**トグル
/// [9.6 節 DS2-01〜DS2-03、DS-01][DS-03]。
///
/// ## なぜ `QooInfrastructure` に置くのか
/// このトグルの消費者は 2 層にまたがる:
/// - UI（`IconGridView`/`InspectorPane`/`QuickLookController`/`StatusBarView`）は
///   **同期的に**読んで描画を決め、値が変わったら再描画される必要がある。
/// - `ThumbnailService`（`actor`）は [DS-05]「非表示中は生成・キャッシュを
///   行わない」を満たすため、I/O を始める直前に読む必要がある。
///
/// 両方が届く最下層がここで、かつ DS-05 は本質的に I/O の関心事なので、
/// I/O を行う層が状態を持つのが素直だと判断した [設計判断]。
/// `DiagnosticLogPreferences` が同じ理由で `QooInfrastructure` に
/// `UserDefaults` キーを持っているのと同じ位置づけ。
///
/// ## 単一の情報源であること
/// **値を二重に持たない。** 当初は「UI 側が真の状態を持ち、`ThumbnailService`
/// へ非同期に押し込む」形も検討したが、押し込みの完了とビューの再評価の
/// 順序を保証できず、「表示に戻した直後だけサービスがまだ非表示だと思って
/// いて `nil` を返し、サムネイルが出ないまま固まる」競合が生じ得る。
/// この型ひとつを両者が読むことで、その競合自体を無くしている。
///
/// ## `@AppStorage` を使わない理由
/// 初期値を `UserDefaults` から**素の値として一度だけ**読み、変更時に明示的に
/// 書き戻す [`MainWindowView.isRightPaneCollapsed` と同じパターン]。
/// `@AppStorage` をビュー構造を決める `if` 条件で直接読むと SwiftUI の
/// Observation が無限に再評価してハングする既知の不具合があるため
/// （CLAUDE.md「タブバー表示トグル」参照）、そのパターンを踏まない。
@MainActor
@Observable
public final class ThumbnailVisibility {
    public static let shared = ThumbnailVisibility()

    /// 環境設定 UI からも同じキーを参照できるよう公開する。
    public static let globallyHiddenKey = "qoo.thumbnails.globallyHidden"

    /// **監視対象から外す**（`@ObservationIgnored`）。`UserDefaults` 自体は
    /// 変化を通知しないうえ、書き戻し用に持っているだけで表示には関与しない。
    @ObservationIgnored private let defaults: UserDefaults

    /// 全体トグル [DS-01]。`true` なら**すべての**ウインドウ・タブで
    /// サムネイルを出さない [DS-03]。
    ///
    /// これは「ユーザーが明示的に切り替えた全体設定」であり、
    /// 実際にそのウインドウでサムネイルが出るかどうか（＝ライブラリ側の
    /// 強制非表示 [DS-04] も加味した実効値）とは別物。実効値の判定は
    /// 「今どの登録フォルダの中にいるか」を知っている UI 層が行う
    /// [`WindowState.thumbnailHiddenReason`]。
    public private(set) var isGloballyHidden: Bool

    /// 全体トグルの変化を外へ知らせる口（現状の唯一の利用者はバックグラウンドの
    /// 動画サムネイル生成 [`BackgroundThumbnailWarmer`]。非表示で掃引を止め、
    /// 表示に戻したら再開する）。アプリ起動時に `qooLibraryApp` が設定する。
    ///
    /// **この型が `BackgroundThumbnailWarmer.shared` を直接呼ばないのは、
    /// テストが独立インスタンスを作って `setGloballyHidden` を呼んだときに、
    /// 実物の掃引を巻き込まないため**（配線されていなければ何も起きない）。
    @ObservationIgnored public var onGlobalVisibilityChanged: ((Bool) -> Void)?

    /// テストでは独立した `UserDefaults` を注入できる（`RegisteredFolderStore`
    /// 等が `storageURL` を注入できるのと同じ理由。プロセス共有の
    /// `UserDefaults.standard` を書き換えるテストは並行実行で干渉する）。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isGloballyHidden = defaults.bool(forKey: Self.globallyHiddenKey)
    }

    public func setGloballyHidden(_ hidden: Bool) {
        guard hidden != isGloballyHidden else { return }
        isGloballyHidden = hidden
        defaults.set(hidden, forKey: Self.globallyHiddenKey)
        onGlobalVisibilityChanged?(hidden)
    }

    /// メニューバー・キーバインド（既定 `⌃⌘I`）・ステータスバーのボタンから
    /// 呼ぶ [DS-02][DS-07]。
    public func toggleGlobal() {
        setGloballyHidden(!isGloballyHidden)
    }
}
