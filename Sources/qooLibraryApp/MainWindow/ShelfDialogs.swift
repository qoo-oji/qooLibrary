//
//  シェルフの入力ダイアログ [SH-01][SH-03]。
//
//  **入口が 2 つあるので実装を 1 つにする** — 左ペインの「＋」と、メニューバー
//  「ライブラリ」→「シェルフとして保存…」。同じに見える操作に独立した経路を
//  作ると、片方だけ直して取り残す（このコードベースが繰り返し踏んでいる形
//  ——1-12 のアプリ関連付け、DS-04 の Quick Look、登録ルート行の 2 行型）。
//
import QooApplication
import QooKit
import SwiftUI

enum ShelfDialogs {
    /// シェルフのコマンドを実行する唯一の経路 [SH-01〜SH-04]。
    ///
    /// **失敗は握りつぶさない** [ER-01]——保存も改名も削除も、押した結果が
    /// 画面に出ないまま黙って何も起きないのがいちばん分かりにくい。
    /// 一覧の読み直しは `MainWindowView` の `.task(id:)` が駆動する（鍵に
    /// 世代番号を含めてあるので ⌘Z にも追随する）。
    @MainActor
    static func run(_ command: some Command, whatHappened: String) {
        Task {
            do {
                _ = try await CommandStack.shared.run(command)
            } catch {
                guard !CommandStack.isCancellation(error) else { return }
                _ = await NotificationRouter.shared.presentError(
                    error, whatHappened: whatHappened)
            }
        }
    }

    /// いまの絞り込みに名前を付けて保存する [SH-01]。
    ///
    /// **条件が空なら何もしない** [SH-07]。呼び出し側もボタンを無効にしているが、
    /// 判定をここにも置くのは、入口が増えたときに素通りさせないため。
    @MainActor
    static func presentSave(libraryID: LibraryID,
                            condition: ShelfCondition,
                            services: LibraryServices,
                            locale: Locale) {
        guard condition.isActive else { return }
        DialogWindowPresenter.shared.present(
            title: String(localized: "labelFilter.shelfSaveTitle", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "labelFilter.shelfNamePlaceholder", locale: locale),
                confirmTitle: String(localized: "common.save", locale: locale),
                initialName: ""
            ) { name in
                run(CreateShelfCommand(libraryID: libraryID, name: name,
                                       condition: condition, services: services),
                    whatHappened: String(localized: "labelFilter.shelfSaveTitle", locale: locale))
            }
        }
    }

    /// 改名 [SH-03]。**同名を拒まない**——一意性を課すと「自分自身と衝突する」
    /// 判定が要り、そこは先行実装（Calibre の保存済み検索）が実際に壊した箇所
    /// である（`ShelfRepository.create` のコメント参照）。
    @MainActor
    static func presentRename(_ shelf: ShelfSummary,
                              services: LibraryServices,
                              locale: Locale) {
        DialogWindowPresenter.shared.present(
            title: String(localized: "labelFilter.shelfRenameTitle", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "labelFilter.shelfNamePlaceholder", locale: locale),
                confirmTitle: String(localized: "action.rename", locale: locale),
                initialName: shelf.name
            ) { name in
                guard name != shelf.name else { return }
                run(RenameShelfCommand(shelfID: shelf.id, previousName: shelf.name,
                                       newName: name, services: services),
                    whatHappened: String(localized: "labelFilter.shelfRenameTitle", locale: locale))
            }
        }
    }
}
