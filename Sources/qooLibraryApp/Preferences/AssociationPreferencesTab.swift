import AppKit
import QooApplication
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「ビューア」タブ（旧「関連付け」。ユーザー指摘を受けて表示名を
/// 変更 — 実体はダブルクリック／Enter でファイルを開くときの既定アプリ
/// （対応するビューア）を指定するだけの設定であり、「関連付け」という名前は
/// macOS の他の意味（Finder 全体の既定関連付け等）と紛らわしいため）
/// [12章 §12.9、AS-01〜AS-07 の実装可能な範囲]。**qooLibrary 内部だけの
/// 上書きで、macOS システム全体の既定関連付けは変更しない**
/// （`AppAssociationService` のコメント参照）。
///
/// **[訂正・統合] 当初は「組み込み（常時表示・削除不可）」と「カスタム
/// （ユーザー追加、削除可）」を別セクションで管理していたが、ユーザーから
/// 「もう既定の拡張子とカスタム拡張子を分離する意味はない」との指摘を受け、
/// 単一の一覧に統合した。** このタブは単に「ダブルクリック／Enter で開く
/// アプリ」を指定するだけの設定であり、qooLibrary が中身を読めるかどうか
/// （サムネイル生成対応など、`ThumbnailService` 側の別の独立した関心事）とは
/// 無関係——「組み込み」を特別扱いする理由は元々無かった。zip/cbz・7z/cb7・
/// rar/cbr・pdf/epub は初回起動時に `AppAssociationStore` が既定でこの一覧に
/// 加えるだけの「最初から入っている項目」であり、他の項目と全く同じ操作
/// （追加・削除）ができる。**既存の拡張子をユーザーが削除した後、将来の
/// バージョンで既定拡張子が増えても、それによってユーザーの一覧が上書き・
/// マージされることはない**（`AppAssociationStore.ensureLoaded` 参照 —
/// 一度でも永続化ファイルが存在すればこの既定値は二度と参照されない）。
///
/// `tar.gz` は複合拡張子で `UTType(filenameExtension:)` に単純に渡せない
/// ため、このタブの対象からは除外している（比較的マイナーな形式でもあり、
/// スコープを絞った）[設計判断]。
struct AssociationPreferencesTab: View {
    @Environment(\.locale) private var locale
    private let service: AppAssociationService = AppAssociationStore.shared

    @State private var candidatesByExtension: [String: [AppCandidate]] = [:]
    @State private var primaryByExtension: [String: String] = [:] // 拡張子 → bundleID（未設定は無し）
    /// `candidates(for:)`（`urlsForApplications` の結果）に現れないのに既定に
    /// 設定されているアプリ。コンテキストメニューの「常にこのアプリケーションで
    /// 開く > その他…」で、その拡張子の UTType を宣言していないアプリを選んだ
    /// 場合に起きる。選択肢に足さないと `Picker` がどのタグにも一致せず空欄に
    /// なり、しかも触った瞬間に黙って別のアプリへ置き換わってしまう
    /// [code-review の指摘]。
    @State private var unlistedPrimaryByExtension: [String: AppCandidate] = [:]
    @State private var extensions: [String] = []
    @State private var newExtensionText = ""
    @State private var addExtensionErrorKey: String?

    var body: some View {
        Form {
            Section {
                // 画像フォルダ（ブックフォルダ [IF-01]）の「開くアプリ」。
                // 拡張子を持たないので擬似キー [`AppAssociationKeys.folder`] で
                // 保存し、専用の行として常に描く（削除ボタンは付けない——
                // 拡張子の管理一覧の項目ではないため）[§19.10 ステージ 2]。
                folderAssociationRow

                ForEach(extensions, id: \.self) { ext in
                    HStack {
                        associationRow(for: ext)
                        Button {
                            removeExtension(ext)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    TextField("preferences.associations.addExtensionPlaceholder", text: $newExtensionText)
                        .editableFieldChrome()
                        .onSubmit { addExtension() }
                    Button("preferences.associations.add") { addExtension() }
                        .disabled(newExtensionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addExtensionErrorKey {
                    Text(LocalizedStringKey(addExtensionErrorKey))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("preferences.associations.header")
            } footer: {
                Text("preferences.associations.footer")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task {
            await reload()
        }
    }

    /// 画像フォルダの行。`associationRow(for:)` と同じ形だが、題は拡張子の
    /// 大文字化ではなく訳語、候補は `candidatesForFolders()`（`public.folder`
    /// ベース。拡張子からは引けない）。
    private var folderAssociationRow: some View {
        let key = AppAssociationKeys.folder
        return LabeledContent(String(localized: "preferences.associations.folderRow", locale: locale)) {
            Picker("preferences.associations.folderRow", selection: primaryBinding(for: key)) {
                Text("preferences.associations.systemDefault").tag(Optional<String>.none)
                ForEach(options(for: key)) { candidate in
                    Label {
                        Text(candidate.name)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                    }
                    .tag(Optional(candidate.bundleID))
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func associationRow(for ext: String) -> some View {
        LabeledContent(ext.uppercased()) {
            Picker(ext.uppercased(), selection: primaryBinding(for: ext)) {
                Text("preferences.associations.systemDefault").tag(Optional<String>.none)
                ForEach(options(for: ext)) { candidate in
                    Label {
                        Text(candidate.name)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.url.path))
                    }
                    .tag(Optional(candidate.bundleID))
                }
            }
            .labelsHidden()
        }
    }

    /// 候補アプリに、一覧へ現れない既定アプリを補った選択肢
    /// （`unlistedPrimaryByExtension` のコメント参照）。
    private func options(for ext: String) -> [AppCandidate] {
        var list = candidatesByExtension[ext] ?? []
        if let unlisted = unlistedPrimaryByExtension[ext],
           !list.contains(where: { $0.bundleID == unlisted.bundleID }) {
            list.append(unlisted)
        }
        return list
    }

    private func primaryBinding(for ext: String) -> Binding<String?> {
        Binding(
            get: { primaryByExtension[ext] },
            set: { newValue in
                primaryByExtension[ext] = newValue
                Task {
                    do {
                        try await service.setPrimary(newValue, for: ext)
                    } catch {
                        // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の
                        // 一掃]。楽観更新した表示は実際の保存内容へ読み直して戻す。
                        await NotificationRouter.shared.presentError(
                            error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                        )
                        await refreshPrimary(for: ext)
                    }
                }
            }
        )
    }

    /// 入力文字列を拡張子として正規化する（前後の空白除去・小文字化・先頭の
    /// `.` 除去）。英数字以外を含む場合は `nil`（無効な拡張子）。
    private func normalizeExtension(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return trimmed
    }

    private func addExtension() {
        guard let ext = normalizeExtension(newExtensionText) else {
            addExtensionErrorKey = "preferences.associations.invalidExtension"
            return
        }
        guard !extensions.contains(ext) else {
            addExtensionErrorKey = "preferences.associations.duplicateExtension"
            return
        }
        addExtensionErrorKey = nil
        newExtensionText = ""
        extensions.append(ext)
        extensions.sort()
        candidatesByExtension[ext] = service.candidates(for: ext)
        Task {
            do {
                try await service.addExtension(ext)
                await refreshPrimary(for: ext)
            } catch {
                // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の一掃]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                )
                await reload()
            }
        }
    }

    private func removeExtension(_ ext: String) {
        extensions.removeAll { $0 == ext }
        candidatesByExtension.removeValue(forKey: ext)
        primaryByExtension.removeValue(forKey: ext)
        unlistedPrimaryByExtension.removeValue(forKey: ext)
        Task {
            do {
                try await service.removeExtension(ext)
            } catch {
                // 保存失敗を握りつぶさない [ER-01、2026-08 既知の不具合の一掃]。
                await NotificationRouter.shared.presentError(
                    error, whatHappened: String(localized: "error.operationFailed", locale: locale)
                )
                await reload()
            }
        }
    }

    private func reload() async {
        extensions = await service.extensions()
        for ext in extensions {
            candidatesByExtension[ext] = service.candidates(for: ext)
            await refreshPrimary(for: ext)
        }
        // 画像フォルダの擬似キー行 [§19.10 ステージ 2]。`extensions()` には
        // 載らない（拡張子ではない）ので、ここで独立に読み込む。
        candidatesByExtension[AppAssociationKeys.folder] = service.candidatesForFolders()
        await refreshPrimary(for: AppAssociationKeys.folder)
    }

    /// 既定アプリを読み直し、`candidates(for:)` に含まれない場合は
    /// `unlistedPrimaryByExtension` へ退避する（`options(for:)` 参照）。
    private func refreshPrimary(for ext: String) async {
        let primary = await service.primary(for: ext)
        primaryByExtension[ext] = primary?.bundleID
        if let primary, !(candidatesByExtension[ext] ?? []).contains(where: { $0.bundleID == primary.bundleID }) {
            unlistedPrimaryByExtension[ext] = primary
        } else {
            unlistedPrimaryByExtension.removeValue(forKey: ext)
        }
    }
}
