import QooInfrastructure
import SwiftUI

/// アバウト画面 [LC-25]。UnRAR の帰属表示（使用の旨・著作者・
/// 「RAR互換アーカイバの開発に使用してはならない」旨）を掲載する。
/// libarchive（BSD-2-Clause）についても併記する。全文は
/// `THIRD-PARTY-NOTICES.md` を参照。
struct AboutView: View {
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
                    Text("qooLibrary")
                        .font(.system(size: Tokens.fontSize.title1, weight: .bold))
                    Text("バージョン \(appVersion)")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("RAR アーカイブの展開について")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        Text(
                            "本アプリの RAR / CBR アーカイブの展開には、現在のビルド構成では "
                                + "\(ArchiveBackendRegistry.rarBackendName) を使用しています。"
                        )
                        .font(.system(size: Tokens.fontSize.body))
                        Text(
                            "UnRAR は Alexander Roshal 氏（RARLAB）による著作物です。"
                                + "UnRAR のソースコードおよびこれを利用するコードは、"
                                + "RAR 互換アーカイバの開発に使用してはなりません。"
                        )
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Tokens.spacing.xs) {
                        Text("zip / 7z / tar.gz アーカイブの展開について")
                            .font(.system(size: Tokens.fontSize.body, weight: .semibold))
                        Text("libarchive（BSD-2-Clause ライセンス）を使用しています。")
                            .font(.system(size: Tokens.fontSize.caption))
                            .foregroundStyle(.secondary)
                    }

                    Text("サードパーティ製ソフトウェアの全ライセンス条文は THIRD-PARTY-NOTICES.md を参照してください。")
                        .font(.system(size: Tokens.fontSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Tokens.spacing.l)
        .frame(width: 420, height: 360)
    }
}
