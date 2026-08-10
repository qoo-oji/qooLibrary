import AppKit
import QooInfrastructure
import SwiftUI

/// 1-2（サンドボックス + Security-Scoped Bookmark 基盤、FS 適合検証）の
/// 実機検証用デバッグ UI。`swift test` はサンドボックス外で動くため、
/// 実際のサンドボックス強制・ブックマークの再起動をまたいだ永続性は
/// ここでしか確認できない。
///
/// フォルダ登録の本実装（1-13）ができたら削除し、登録フローに置き換える。
@MainActor
@Observable
final class SandboxVerificationModel {
    private(set) var log: [String] = []
    private var lastBookmark: Data? {
        didSet { UserDefaults.standard.set(lastBookmark, forKey: Self.bookmarkKey) }
    }

    var hasSavedBookmark: Bool { lastBookmark != nil }

    private static let bookmarkKey = "qoo.debug.lastBookmark"
    private let bookmarkResolver = SecurityScopedBookmarkResolver()
    private let volumeChecker = VolumeEligibilityChecker()

    init() {
        lastBookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
    }

    func pickFolderAndVerify() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダで検証"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        append("--- 新規選択: \(url.path) ---")
        do {
            let data = try bookmarkResolver.makeBookmark(for: url)
            lastBookmark = data
            append("ブックマーク作成成功（\(data.count) bytes）[RG-07]")
        } catch {
            append("ブックマーク作成失敗: \(error)")
            return
        }
        Task { await runFullVerification() }
    }

    func resolveSavedBookmark() {
        append("--- 保存済みブックマークを解決（アプリ再起動をまたいだ永続性の確認）[SB-02] ---")
        Task { await runFullVerification() }
    }

    private func runFullVerification() async {
        guard let data = lastBookmark else {
            append("保存済みブックマークがありません。まずフォルダを選択してください。")
            return
        }
        switch bookmarkResolver.resolve(data) {
        case .resolved(let url, let isStale):
            append("解決成功: \(url.path)（stale: \(isStale)）")
            await verifyEligibilityAndAccess(url: url, bookmark: data)
        case .offline(let reason):
            // [SB-05] 解決失敗は例外を投げず .offline を返す設計。
            append("オフライン: \(reason)")
        }
    }

    private func verifyEligibilityAndAccess(url: URL, bookmark: Data) async {
        // [バグ修正] FS 適合検証（tmpA の作成を伴う）は startAccessingSecurityScopedResource
        // が有効な区間の中で行わないと、ブックマーク解決のみ（NSOpenPanel の新規選択ではない
        // 経路）では書き込み権限がなく probeSetupFailed になる。NSOpenPanel 直後の URL は
        // 暗黙に書き込み可だったため、初回の手動検証ではこのバグが表面化しなかった
        // （実機検証で発見。詳細は CLAUDE.md/コミットログ参照）。
        let checker = volumeChecker
        do {
            let (eligibility, count) = try await bookmarkResolver.withAccess(bookmark) { accessedURL in
                let eligibility = try await checker.evaluate(accessedURL)
                let count = try FileManager.default.contentsOfDirectory(atPath: accessedURL.path).count
                return (eligibility, count)
            }
            switch eligibility {
            case .eligible(let warnings):
                append("FS 適合検証: 合格" + (warnings.isEmpty ? "" : "（警告: \(warnings)）"))
            case .rejected(let reason):
                append("FS 適合検証: 却下 — \(reason)")
            }
            append("セキュリティスコープ内でのアクセス成功: \(count) 件")
        } catch {
            append("検証中にエラー: \(error)")
        }
    }

    private func append(_ line: String) {
        log.append(line)
    }
}

struct SandboxVerificationView: View {
    @State private var model = SandboxVerificationModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.s) {
            Text("1-2 検証用ツール")
                .font(.system(size: Tokens.fontSize.title3, weight: .semibold))
            Text("フォルダ登録の本実装（1-13）までの暫定デバッグ UI。")
                .font(.system(size: Tokens.fontSize.caption))
                .foregroundStyle(.secondary)

            HStack(spacing: Tokens.spacing.s) {
                Button("フォルダを選択して検証") { model.pickFolderAndVerify() }
                Button("保存済みブックマークを解決") { model.resolveSavedBookmark() }
                    .disabled(!model.hasSavedBookmark)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: Tokens.fontSize.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.spacing.s)
            }
            .frame(minHeight: 160)
            .background(Tokens.Colors.listAlternate)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.m))
        }
        .padding(Tokens.spacing.l)
    }
}
