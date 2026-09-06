//
//  ボリューム／フォルダへのアクセス許可の付与 [SB-03][SB-04]。
//
//  **環境設定「アクセス権」タブと初回セットアップウィザードのステップ 2 が
//  共有する唯一の実装。** 同じに見える操作に独立した経路を 2 つ作ると、片方
//  だけ直して取り残す（1-12 のアプリ関連付けで実際に起きた）。
//
import AppKit
import QooApplication
import QooInfrastructure
import SwiftUI

@MainActor
enum VolumeAccessAction {

    /// `NSOpenPanel` を出し、選ばれた場所を Security-Scoped Bookmark として
    /// 許可する。付与できたら `true`、利用者がキャンセルしたら `false`。
    ///
    /// **既定の行き先はルート（起動ボリューム）** [SW-08]。実機検証で
    /// **起動ボリューム 1 件の許可でマウント中の外部ボリュームまで到達できる**
    /// ことを確認しており、そのまま「選択」を押すだけで済む。
    @discardableResult
    static func requestGrant(locale: Locale) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = AppStrings.text("preferences.access.panelMessage", locale: locale)
        panel.directoryURL = URL(fileURLWithPath: "/")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            _ = try await VolumeAccessStore.shared.grantAccess(to: url, displayName: nil)
            // フォルダツリーが既にキャッシュしている「アクセス権がありません」
            // 状態を再読み込みさせる（`FolderTreePane` の
            // `SessionState.reloadToken` 監視と対になる）。
            SessionState.shared.reloadToken += 1
            return true
        } catch {
            await NotificationRouter.shared.presentError(
                error,
                whatHappened: AppStrings.text("error.operationFailed", locale: locale))
            return false
        }
    }
}
