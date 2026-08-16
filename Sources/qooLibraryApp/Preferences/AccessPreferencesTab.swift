import AppKit
import QooApplication
import QooInfrastructure
import SwiftUI

/// 環境設定「アクセス権」タブ [ユーザー要望、要件定義書には無い]。
///
/// フルディスクアクセスを付与しても App Sandbox のカーネルレベルのファイル
/// 読み取り制限は回避されないことが実機検証で判明した（CLAUDE.md 1-4 節
/// 「将来検討」の訂正、動画サムネイル対応の調査中に発覚）。代わりに
/// `NSOpenPanel` によるユーザーの明示的な選択で Security-Scoped Bookmark を
/// 作り、`VolumeAccessStore` に永続化する。フォルダツリーでアクセス権が無い
/// ボリューム/フォルダを展開しようとしたときの `AccessDeniedRow`
/// （`FolderTreePane.swift`）からも同じ経路で許可を追加できる——このタブは
/// 既に許可したものを一覧・管理する場所という位置づけ（qooViewer に前例のある
/// 構成）。
struct AccessPreferencesTab: View {
    @Environment(\.locale) private var locale
    @State private var grants: [GrantedVolumeAccess] = []

    var body: some View {
        Form {
            Section {
                if grants.isEmpty {
                    Text("preferences.access.empty")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(grants) { grant in
                        HStack {
                            Text(grant.displayName)
                            Spacer()
                            Button {
                                revoke(grant)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("preferences.access.addEllipsis") { addAccess() }
            } header: {
                Text("preferences.access.header")
            } footer: {
                Text("preferences.access.footer")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task { await reload() }
    }

    private func addAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "preferences.access.panelMessage", locale: locale)
        // 起動ボリューム（Macintosh HD）を許可すると、実機検証の結果マウント中の
        // 外部ボリュームもまとめてアクセス可能になることを確認した
        // [ユーザー要望]。最小限の操作（そのまま「選択」を押すだけ）で選べる
        // よう、既定でルート（起動ボリューム自身）を指す状態でパネルを開く。
        panel.directoryURL = URL(fileURLWithPath: "/")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await VolumeAccessStore.shared.grantAccess(to: url, displayName: nil)
                await reload()
                // フォルダツリーが既にキャッシュしている「アクセス権がありません」
                // 状態を再読み込みさせる [`FolderTreePane` の `SessionState.reloadToken`
                // 監視と対になる、`AccessDeniedRow` 経由の許可と同じ理由]。
                SessionState.shared.reloadToken += 1
            } catch {
                await NotificationRouter.shared.presentError(error, whatHappened: String(localized: "error.operationFailed", locale: locale))
            }
        }
    }

    private func revoke(_ grant: GrantedVolumeAccess) {
        Task {
            do {
                try await VolumeAccessStore.shared.revokeAccess(grant.id)
            } catch {
                // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の一掃]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                )
            }
            await reload()
            // [実機検証で発見・修正したバグ] 取り消しても既に読み込み済みの
            // フォルダツリーの行はキャッシュされたままだったため、明示的に
            // 再読み込みさせる（`FolderTreePane` の `SessionState.reloadToken`
            // 監視参照）。
            SessionState.shared.reloadToken += 1
        }
    }

    private func reload() async {
        grants = await VolumeAccessStore.shared.grantedAccess()
    }
}
