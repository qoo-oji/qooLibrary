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
struct AssociationPreferencesTab: View {
    @Environment(\.locale) private var locale
    private let service: AppAssociationService = AppAssociationStore.shared
    private static let extensions = ["zip", "cbz", "7z", "cb7", "rar", "cbr"]

    @State private var candidatesByExtension: [String: [AppCandidate]] = [:]
    @State private var primaryByExtension: [String: String] = [:] // 拡張子 → bundleID（未設定は無し）

    var body: some View {
        Form {
            Section {
                ForEach(Self.extensions, id: \.self) { ext in
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

    private func reload() async {
        for ext in Self.extensions {
            candidatesByExtension[ext] = await service.candidates(for: ext)
            primaryByExtension[ext] = await service.primary(for: ext)?.bundleID
        }
    }
}
