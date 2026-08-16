import Foundation
import QooApplication
import QooInfrastructure
import QooKit

/// **起動時に、置き換えの途中で見失ったファイルを取り戻す** [NV-92]。
///
/// `.replace`（[FM-13]「置き換える」）は既存の項目をいったん退避してから書く。
/// その間に落ちる／切断されると、**ユーザーの元ファイルが
/// `.qoo-replace-backup-<UUID>` の名前のまま残る**。先頭がドットなので
/// Finder にも本アプリにも見えず、ユーザーから見れば消えている。
///
/// `ReplaceBackupJournal` が「作る前に記録し、片付けたら消す」ことで
/// 居場所を持っているので、ここはそれを読んで戻すだけ。走査は 1 回も行わない
/// （通常時は記録ファイルが存在せず、何も起きない）。
///
/// ## なぜアプリ層に置くのか
/// 復旧そのものはインフラ層（`ReplaceBackupJournal.recoverAll()`）が担い、
/// **ここは結果をユーザーへどう伝えるかだけ**を持つ。エラーの提示は
/// `NotificationRouter` に一本化されている [ER-01] ため、インフラ層からは
/// 直接呼べない（`FileOperationService` が提示せずエラーを返すのと同じ分担）。
enum ReplaceBackupRecovery {
    /// - Note: 記録の読み書きはファイル I/O なので `FileIO` 経由で行う
    ///   [NV6-01]。退避先がネットワーク上なら、`moveItem` は切断時に
    ///   応答しないことがある。
    static func runAtStartup() async {
        let outcomes = await FileIO.perform { ReplaceBackupJournal.shared.recoverAll() }
        guard !outcomes.isEmpty else { return }

        let restored = outcomes.compactMap { outcome -> URL? in
            if case let .restored(target) = outcome { return target }
            return nil
        }
        let orphaned = outcomes.compactMap { outcome -> (backup: URL, target: URL, reason: String)? in
            if case let .orphaned(backup, target, reason) = outcome { return (backup, target, reason) }
            return nil
        }

        // **戻せたものも黙って済ませない。** ユーザーは前回「ファイルが
        // 消えた」と認識している可能性があり、戻ったことを知る手段が要る。
        // ただし判断は不要なので一時通知にとどめる [ER-02]。
        if !restored.isEmpty {
            await NotificationRouter.shared.present(NotificationItem(
                category: .info,
                severity: .transient,
                title: String(localized: "replaceBackup.restored.title"),
                body: String(
                    format: String(localized: "replaceBackup.restored.body"),
                    restored.count, restored.map(\.lastPathComponent).joined(separator: "\n")
                ),
                technicalDetail: restored.map(\.path).joined(separator: "\n")
            ))
        }

        // 戻せなかったものは**ユーザーが動かないと直らない**ので、
        // 見逃せない強度で出す [ER-02]。
        if !orphaned.isEmpty {
            await NotificationRouter.shared.present(NotificationItem(
                category: .error,
                severity: .sheet,
                title: String(localized: "replaceBackup.orphaned.title"),
                body: String(
                    format: String(localized: "replaceBackup.orphaned.body"),
                    orphaned.count,
                    orphaned.map { "\($0.target.lastPathComponent) ← \($0.backup.lastPathComponent)" }
                        .joined(separator: "\n")
                ),
                technicalDetail: orphaned
                    .map { "\($0.backup.path)\n→ \($0.target.path)\n\($0.reason)" }
                    .joined(separator: "\n\n")
            ))
        }
    }
}
