import QooInfrastructure
import SwiftUI

/// アバウト画面 [LC-25]。UnRAR の帰属表示（使用の旨・著作者・
/// 「RAR互換アーカイバの開発に使用してはならない」旨）を掲載する。
/// libarchive（BSD-2-Clause）についても併記する。全文は
/// `THIRD-PARTY-NOTICES.md` を参照。
struct AboutView: View {
    /// `Text` の `LocalizedStringKey` 解決と違い、View の外で組み立てる
    /// 文字列は `.environment(\.locale)` を自動的には見ないため、ここで読んで
    /// `AppStrings` へ渡す。**`String(localized:locale:)` は使えない**
    /// ——`locale:` は書式にしか効かず `.lproj` を選ばない［実測 2026-09-06］。
    @Environment(\.locale) private var locale

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            HStack(spacing: Tokens.spacing.m) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Tokens.Colors.accent)
                VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                    Text(verbatim: "qooLibrary")
                        .font(.system(size: Tokens.fontSize.title1, weight: .bold))
                    Text(localized("about.version", appVersion))
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("about.rarSectionTitle")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        Text(localized("about.rarBackend", ArchiveBackendRegistry.rarBackendName))
                            .font(.system(size: Tokens.fontSize.body))
                        Text("about.rarAttribution")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("about.libarchiveSectionTitle")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        Text("about.libarchiveAttribution")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }

                    Text("about.thirdPartyNotice")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Tokens.spacing.l)
        .frame(width: 420, height: 360)
    }

    /// 動的な値を1つ埋め込む文字列用のヘルパー。`%@` テンプレートの
    /// `String(format:)` を使う（複数値の埋め込みが必要な箇所は
    /// `KeyboardPreferencesTab.swift` と同じ理由で同じ方式にしている）。
    private func localized(_ key: String, _ value: String) -> String {
        String(format: AppStrings.text(key, locale: locale), value)
    }
}
