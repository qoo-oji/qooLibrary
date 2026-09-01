//
//  右ペインのカバー画像 [CV-01〜CV-08][DS-06]。
//
//  解決順序（①ユーザー指定 → ②サイドカー → ③先頭画像）は
//  `CoverEditorModel`（`QooApplication`）が持つ。この View は
//  「モデルが指した URL のサムネイルを描き、差し替えの入口を並べる」だけ。
//
import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorCoverSection: View {
    /// 対象そのもの。**ライブラリ経由でなくても描く**——カバーの差し替えは
    /// できないが、サムネイルの表示 [IV-01] は従来どおり行う。
    let url: URL
    let thumbnailsHidden: Bool
    let model: CoverEditorModel

    @Environment(\.locale) private var locale
    /// D&D 中の枠 [CV-03]。
    @State private var isDropTargeted = false

    private var subject: CoverEditorModel.Subject? {
        if case .ready(let subject) = model.state { return subject }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
            InspectorThumbnail(url: subject?.previewURL ?? url,
                               thumbnailsHidden: thumbnailsHidden)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: Tokens.radius.m)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                // [CV-03] カバー画像の上へのドロップで差し替える。**ライブラリ
                // 経由のときだけ受け取る**——受け取れないところで枠だけ光ると、
                // 落としたのに何も起きない理由が読めない。
                .dropDestination(for: URL.self) { urls, _ in
                    guard subject != nil, let dropped = urls.first else { return false }
                    Task { await replace(fromFile: dropped) }
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted && subject != nil
                }
                // **差し替えの操作はカバーの右クリックに置く**
                // ［ユーザー指摘、2026-09-02］。以前は右ペインの上に
                // 「変更…」「ページから選ぶ…」というリンクを並べていたが、
                // **何に対する操作なのかが読み取れなかった**——右ペインの
                // 上端はファイル名より上で、下に続く欄との関係も無い。
                // カバーそのものに付ければ対象が自明になる。
                .contextMenu { if let subject { coverMenu(subject) } }
                .help(subject == nil ? "" : String(localized: "inspector.cover.hint",
                                                   locale: locale))
            if let subject { sourceCaption(subject) }
        }
    }

    // MARK: - 部品

    /// いま何が出ているか [IV-03]。**自動のときは黙る**——既定の状態に
    /// 説明が常駐すると、特別なことが起きているように見える。
    @ViewBuilder
    private func sourceCaption(_ subject: CoverEditorModel.Subject) -> some View {
        switch subject.resolvedSource {
        case .userSpecified: caption("inspector.cover.sourceUser")
        case .sidecar: caption("inspector.cover.sourceSidecar")
        case .auto: EmptyView()
        }
    }

    /// カバーの右クリック [CV-04][CV-05][CV-07]。
    @ViewBuilder
    private func coverMenu(_ subject: CoverEditorModel.Subject) -> some View {
        Button("inspector.cover.chooseFile", systemImage: "photo") {
            Task { await chooseFile() }
        }
        if subject.canPickFromArchive {
            Button("inspector.cover.choosePage", systemImage: "doc.text.image") {
                // [CV-05] 独立したモーダルウインドウで出す（右ペインは
                // 幅が狭く、ページの一覧を縦に積むと必ず隠れる。
                // `AddLabelDialog` と同じ約束）。
                DialogWindowPresenter.shared.present(
                    title: String(localized: "inspector.cover.choosePageTitle", locale: locale)
                ) { _ in
                    ArchiveCoverPickerDialog(url: subject.url) { data in
                        Task { await replace(withData: data) }
                    }
                }
            }
        }
        if subject.canRevert {
            // [CV-07] **ユーザー指定のときだけ出す**——自動のまま
            // 「既定に戻す」が常駐しても何も起きない。
            Divider()
            Button("inspector.cover.revert", systemImage: "arrow.uturn.backward") {
                Task { await revert() }
            }
        }
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: Tokens.fontSize.caption))
            .foregroundStyle(.secondary)
    }

    // MARK: - 操作

    /// [CV-04] ダイアログから選ぶ。**画像に絞る**——アーカイブや動画を選べる
    /// ようにすると、選んだあとに「画像ではありません」と断ることになる。
    /// アーカイブの中から選ぶ経路は別のボタン [CV-05] が担う。
    private func chooseFile() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "inspector.cover.panelMessage", locale: locale)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        await replace(fromFile: chosen)
    }

    /// 実ファイルを読んで差し替える [CV-02][CV-03][CV-04]。
    ///
    /// **読み込みは上限つき**（`CoverImageSourceResolver`）——拡張子だけを見て
    /// 全量を RAM へ読むと、誤った拡張子の巨大ファイルで枯渇する [F1 の教訓]。
    private func replace(fromFile source: URL) async {
        guard PreviewableFileKind.of(source) == .image else {
            await NotificationRouter.shared.presentError(
                CoverReplacementError.notAnImage,
                whatHappened: String(localized: "error.setCoverFailed", locale: locale))
            return
        }
        guard let data = await CoverImageSourceResolver.firstImageData(for: source) else {
            await NotificationRouter.shared.presentError(
                CoverReplacementError.notAnImage,
                whatHappened: String(localized: "error.setCoverFailed", locale: locale))
            return
        }
        await replace(withData: data)
    }

    private func replace(withData data: Data) async {
        do {
            try await model.replace(withImageData: data)
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setCoverFailed", locale: locale))
        }
    }

    private func revert() async {
        do {
            try await model.revert()
        } catch {
            await NotificationRouter.shared.presentError(
                error, whatHappened: String(localized: "error.setCoverFailed", locale: locale))
        }
    }
}

/// カバーの差し替えで断る理由 [ER-03]。
enum CoverReplacementError: LocalizedError {
    case notAnImage

    var errorDescription: String? {
        String(localized: "error.cover.notAnImage", locale: AppLanguage.effectiveLocale)
    }

    var recoverySuggestion: String? {
        String(localized: "error.cover.notAnImage.recovery", locale: AppLanguage.effectiveLocale)
    }
}
