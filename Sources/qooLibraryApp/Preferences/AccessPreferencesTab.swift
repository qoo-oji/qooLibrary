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

    /// **実装は `VolumeAccessAction` に 1 つだけ** [SB-03]。初回セットアップ
    /// ウィザードのステップ 2 と共有する——同じに見える操作に独立した経路を
    /// 2 つ作ると片方だけ直して取り残す。
    private func addAccess() {
        Task {
            await VolumeAccessAction.requestGrant(locale: locale)
            await reload()
        }
    }

    private func revoke(_ grant: GrantedVolumeAccess) {
        Task {
            do {
                try await VolumeAccessStore.shared.revokeAccess(grant.id)
            } catch {
                // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の一掃]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: AppStrings.text("error.operationFailed", locale: locale)
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
