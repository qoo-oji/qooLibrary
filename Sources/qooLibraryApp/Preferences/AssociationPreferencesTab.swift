import AppKit
import QooInfrastructure
import QooKit
import SwiftUI

/// 環境設定「関連付け」タブ [12章 §12.9、AS-01〜AS-07 の実装可能な範囲]。
/// qooLibrary が実際に読めるアーカイブ拡張子（zip/cbz・7z/cb7・rar/cbr）ごとに
/// 「このアプリで開く」を設定する。**qooLibrary 内部だけの上書きで、macOS
/// システム全体の既定関連付けは変更しない**（`AppAssociationService` の
/// コメント参照）。
///
/// `tar.gz` は複合拡張子で `UTType(filenameExtension:)` に単純に渡せない
/// ため、このタブの対象からは除外している（比較的マイナーな形式でもあり、
/// スコープを絞った）[設計判断]。
///
/// **任意の拡張子を追加できるカスタムセクションを持つ**［ユーザー要望:
/// 本アプリはコミックライブラリ管理が主だが、きちんと設定すれば動画ライブ
/// ラリとしても使える想定のため、任意の動画形式（mp4/mkv 等）を関連付け
/// 対象に追加できるようにしてほしい］。組み込みの6形式は常に表示・削除
/// 不可、カスタム拡張子は `AppAssociationStore` の永続化対象に追加/削除
/// できる。ここで追加した拡張子は「開くアプリ」の設定対象になるだけで、
/// Finder への qooLibrary 自身の登録（`project.yml` の
/// `CFBundleDocumentTypes`）とは無関係 — qooLibrary が実際に読める形式を
/// 増やすものではない点に注意。
struct AssociationPreferencesTab: View {
    @Environment(\.locale) private var locale
    private let service: AppAssociationService = AppAssociationStore.shared
    private static let builtInExtensions = ["zip", "cbz", "7z", "cb7", "rar", "cbr"]

    @State private var candidatesByExtension: [String: [AppCandidate]] = [:]
    @State private var primaryByExtension: [String: String] = [:] // 拡張子 → bundleID（未設定は無し）
    @State private var customExtensions: [String] = []
    @State private var newExtensionText = ""
    @State private var addExtensionErrorKey: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.builtInExtensions, id: \.self) { ext in
                    associationRow(for: ext)
                }
            } header: {
                Text("preferences.associations.header")
            } footer: {
                Text("preferences.associations.footer")
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(customExtensions, id: \.self) { ext in
                    HStack {
                        associationRow(for: ext)
                        Button {
                            removeCustomExtension(ext)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    TextField("preferences.associations.addExtensionPlaceholder", text: $newExtensionText)
                        .onSubmit { addCustomExtension() }
                    Button("preferences.associations.add") { addCustomExtension() }
                        .disabled(newExtensionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addExtensionErrorKey {
                    Text(LocalizedStringKey(addExtensionErrorKey))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("preferences.associations.customHeader")
            } footer: {
                Text("preferences.associations.customFooter")
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

    private func addCustomExtension() {
        guard let ext = normalizeExtension(newExtensionText) else {
            addExtensionErrorKey = "preferences.associations.invalidExtension"
            return
        }
        guard !Self.builtInExtensions.contains(ext), !customExtensions.contains(ext) else {
            addExtensionErrorKey = "preferences.associations.duplicateExtension"
            return
        }
        addExtensionErrorKey = nil
        newExtensionText = ""
        customExtensions.append(ext)
        customExtensions.sort()
        Task {
            try? await service.addCustomExtension(ext)
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
    }

    private func removeCustomExtension(_ ext: String) {
        customExtensions.removeAll { $0 == ext }
        candidatesByExtension.removeValue(forKey: ext)
        primaryByExtension.removeValue(forKey: ext)
        Task {
            try? await service.removeCustomExtension(ext)
        }
    }

    private func reload() async {
        for ext in Self.builtInExtensions {
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
        customExtensions = await service.customExtensions()
        for ext in customExtensions {
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
    }
}
