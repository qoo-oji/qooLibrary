//
//  通知から関連画面へ飛ぶ導線 [NT-05][NW-04]。
//
//  **走査結果のシートと通知履歴ウインドウが同じ経路を使う。** 同じ識別子に
//  対する `switch` を 2 箇所に書くと、片方だけ直して取り残す——このリポジトリが
//  繰り返し踏んでいる形（1-12 のアプリ関連付け、DS-04 の Quick Look、
//  登録ルート行の 2 種類）。行き先を足すときはここ 1 箇所に足す。
//
import QooApplication
import QooKit
import SwiftUI

@MainActor
enum NotificationRouteAction {

    /// 未解決ファイルの整理ウインドウを開く [UR2-02][AL-30]。
    /// **ドットを含めない**——`check-localization-keys` が文字列カタログの鍵と
    /// 誤検出するため（1-15 の実装時に判明）。
    ///
    /// かつてここにあった `review-identity-matches` [ID-05] は同一性確認の
    /// 撤去 [§19.8] とともに消えた——古い履歴の行に残っていても、下の
    /// 「知らない識別子では何もしない」に落ちるだけで害は無い。
    static let reviewUnresolved = "review-unresolved-files"
    /// 巻数の確認ダイアログを開く [EM-30〜EM-35]。
    static let reviewVolumes = "review-volume-decisions"
    /// 見つからないファイルの整理ウインドウを開く [OR2-05][NT-05]。
    static let reviewOrphans = "review-orphaned-files"
    /// プリセット改訂の差分ビューを開く [LT-12][LT-13]。
    static let reviewTemplateUpdate = "review-template-update"

    /// - Returns: 開いたら `true`。**知らない識別子では何もしない**——古い
    ///   通知が、いま存在しない画面を指していることがある（履歴は保持期間の
    ///   ぶんだけ残り、その間にアプリは更新されうる）。
    /// - Parameter openWindow: **`nil` を許す**——自動走査の受け口
    ///   （`qooLibraryApp.init()` が配線する閉包）は View の外にいるので
    ///   `@Environment(\.openWindow)` を持てない。ウインドウを開く行き先は
    ///   その場合だけ静かに諦める（ダイアログで済む行き先は開ける）。
    @discardableResult
    static func perform(actionID: String, libraryID: LibraryID, locale: Locale,
                        openWindow: OpenWindowAction?) -> Bool {
        switch actionID {
        case reviewVolumes:
            VolumeDecisionAction.present(libraryID: libraryID, locale: locale)
        case reviewUnresolved:
            // ステージ 4 で専用ウインドウを廃し、**メインウインドウの一覧**へ
            // 移した [UR3-01][UR3-02]。`openWindow` は要らない——行き先は
            // 既に開いているメインウインドウの中の状態で、開いていなければ
            // 何も起きない（`openWindow` が `nil` のときと同じ扱い）。
            UnresolvedViewNavigation.open(libraryID: libraryID)
        case reviewTemplateUpdate:
            // **ダイアログだが `openWindow` が要る**——適用したら続けて
            // 走査するため（`LibraryEnableAction.rescan` が結果シートから
            // 整理ウインドウを開けるように受け取る）。
            guard let openWindow else { return false }
            TemplateUpdateAction.present(libraryID: libraryID, locale: locale,
                                         openWindow: openWindow)
        case reviewOrphans:
            guard let openWindow else { return false }
            // ステージ 4 で専用ウインドウからメンテナンスのタブへ移した
            // [§19.6]。**タブを明示する**——通知は行き先が決まっているので、
            // 前回開いていたタブのまま出すと押した意味が伝わらない。
            MaintenanceNavigation.open(libraryID: libraryID, tab: .orphans,
                                       openWindow: openWindow)
        default:
            return false
        }
        return true
    }

    /// 履歴の行から開けるか [NW-04]。
    ///
    /// **対象ライブラリが今も DB にあることまで確かめる。** 登録を解除した
    /// あとも通知は履歴に残る（残っていなければ「なぜ消えたのか」を後から
    /// 辿れない）ので、押しても何も起きないボタンが残ることになる。
    static func library(for target: NotificationTarget?,
                        in libraries: [LibrarySummary]) -> LibrarySummary? {
        guard let uuid = target?.libraryUUID else { return nil }
        return libraries.first { $0.uuid == uuid }
    }

    static func canPerform(_ link: NotificationLink, target: NotificationTarget?,
                           in libraries: [LibrarySummary]) -> Bool {
        guard library(for: target, in: libraries) != nil else { return false }
        return [reviewUnresolved, reviewVolumes, reviewOrphans, reviewTemplateUpdate]
            .contains(link.actionID)
    }
}
