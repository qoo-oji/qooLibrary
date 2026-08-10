import QooApplication
import QooInfrastructure
import QooKit
import QooPersistence
import SwiftUI

/// アプリのエントリポイント。
///
/// フェーズ 1 (1-1: プロジェクト基盤) の時点では、3 ペイン構成の骨格と
/// デザイントークンが正しく配線されていることを示すプレースホルダのみを表示する。
/// 実際のフォルダツリー・ファイル一覧・詳細情報は 1-3 以降で実装する。
@main
struct QooLibraryApp: App {
    var body: some Scene {
        WindowGroup {
            ThreePaneWindow(id: "main") {
                PlaceholderPane(title: "フォルダツリー", subtitle: "1-4 で実装")
            } center: {
                PlaceholderPane(
                    title: "qooLibrary",
                    subtitle: "フェーズ 1 (1-1: プロジェクト基盤) 進行中\n"
                        + "モジュール構成: \(QooKit.moduleName) / \(QooPersistence.moduleName) / "
                        + "\(QooInfrastructure.moduleName) / \(QooApplication.moduleName)"
                )
                .background(Tokens.Colors.paneBackground)
            } right: {
                PlaceholderPane(title: "詳細情報", subtitle: "1-10 で実装")
            }
            .frame(minWidth: 900, minHeight: 560)
        }
    }
}

private struct PlaceholderPane: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: Tokens.spacing.s) {
            Text(title)
                .font(.system(size: Tokens.fontSize.title1, weight: .semibold))
            Text(subtitle)
                .font(.system(size: Tokens.fontSize.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
