//
//  草案をテンプレートとして保存する [LT-02]。
//
//  **3 つの入口が共有する唯一の実装**——テンプレート管理ウインドウの
//  「別名で保存…」、ライブラリ設定ウインドウの「テンプレートとして保存…」、
//  登録ウィザードのステップ 4。同じに見える操作に独立した実装を作ると、
//  片方だけ直して取り残す（このコードベースが 9 度踏んでいる形）。
//
//  入力ダイアログは `NameInputDialog`（§13.7.1: 入力系は独立したモーダル
//  ウインドウ）を使う。
//
import QooApplication
import QooKit
import SwiftUI

@MainActor
enum TemplateSaveAction {

    /// 名前を尋ねてから保存する。
    ///
    /// - Parameters:
    ///   - draft: 保存する設定。**呼び出した時点の写しが渡る**ので、
    ///     ダイアログを開いている間に元が変わっても保存される内容は動かない。
    ///   - suggestedName: 入力欄の初期値。
    ///   - onSaved: 保存できたときに呼ぶ（管理ウインドウが新しい行を選ぶのに使う）。
    static func present(draft: LibrarySettingsDraft,
                        suggestedName: String,
                        locale: Locale,
                        onSaved: @escaping (UserTemplate) -> Void = { _ in }) {
        // **不備のあるテンプレートは保存させない** [H1]。呼び出し側でも
        // ボタンを無効にしているが、判断をここにも置く——3 つの入口が
        // 共有する唯一の実装なので、次に入口を足す人が忘れても成立する
        // ［code-review の指摘: ここで守れば全経路に効く］。
        let errors = draft.validate(as: .template).filter { $0.severity == .error }
        guard errors.isEmpty else {
            Task {
                await NotificationRouter.shared.present(NotificationItem(
                    category: .warning, severity: .sheet,
                    title: String(localized: "templates.saveBlockedTitle", locale: locale),
                    body: errors.map(\.message).joined(separator: "\n")))
            }
            return
        }
        DialogWindowPresenter.shared.present(
            title: String(localized: "templates.saveAsTitle", locale: locale)
        ) { _ in
            NameInputDialog(
                placeholder: String(localized: "templates.name", locale: locale),
                confirmTitle: String(localized: "templates.saveAsConfirm", locale: locale),
                initialName: suggestedName
            ) { name in
                Task {
                    do {
                        let saved = try await LibraryServices.shared.saveUserTemplate(
                            UserTemplate(name: name, from: draft))
                        onSaved(saved)
                        // **黙って終わらせない。** この操作は画面をまたぐので
                        // （設定ウインドウで押してもテンプレート一覧は見えない）、
                        // 保存できたことをどこかで言わないと成否が分からない。
                        await NotificationRouter.shared.present(NotificationItem(
                            category: .info, severity: .transient,
                            title: String(format: String(localized: "templates.savedTitle",
                                                         locale: locale), name),
                            body: ""))
                    } catch {
                        await NotificationRouter.shared.presentError(
                            error,
                            whatHappened: String(localized: "templates.saveFailed",
                                                 locale: locale))
                    }
                }
            }
        }
    }
}
