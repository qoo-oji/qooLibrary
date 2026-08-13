import SwiftUI

/// 環境設定「リセット」タブ [ユーザー要望、要件定義書には無い]。将来ここに
/// アプリ内データベース（SwiftData、Phase 2 で導入）を一括削除するボタンを
/// 置く予定だが、**そのボタンより先に、データベースのエクスポート/
/// インポート機能を実装しなければならない**［ユーザーからの明示的な制約。
/// 後戻りできない一括削除を、バックアップ手段が無いまま提供しないため］。
///
/// データベース自体がまだ存在しない現時点ではプレースホルダのみ。
struct ResetPreferencesTab: View {
    var body: some View {
        VStack(spacing: Tokens.spacing.s) {
            Text("preferences.reset.title")
                .font(.system(size: Tokens.fontSize.title1, weight: .semibold))
            Text("preferences.reset.notYetAvailable")
                .font(.system(size: Tokens.fontSize.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
