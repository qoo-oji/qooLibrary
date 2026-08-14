import AppKit
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
    @State private var extensions: [String] = []
    @State private var newExtensionText = ""
    @State private var addExtensionErrorKey: String?

    var body: some View {
        Form {
            Section {
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
                        .textFieldStyle(.roundedBorder)
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

    @ViewBuilder
    private func associationRow(for ext: String) -> some View {
        LabeledContent(ext.uppercased()) {
            Picker(ext.uppercased(), selection: primaryBinding(for: ext)) {
                Text("preferences.associations.systemDefault").tag(Optional<String>.none)
                ForEach(candidatesByExtension[ext] ?? []) { candidate in
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

    private func primaryBinding(for ext: String) -> Binding<String?> {
        Binding(
            get: { primaryByExtension[ext] },
            set: { newValue in
                primaryByExtension[ext] = newValue
                Task {
                    try? await service.setPrimary(newValue, for: ext)
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
        Task {
            try? await service.addExtension(ext)
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
    }

    private func removeExtension(_ ext: String) {
        extensions.removeAll { $0 == ext }
        candidatesByExtension.removeValue(forKey: ext)
        primaryByExtension.removeValue(forKey: ext)
        Task {
            try? await service.removeExtension(ext)
        }
    }

    private func reload() async {
        extensions = await service.extensions()
        for ext in extensions {
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
    }
}
