//
//  メンテナンスウインドウのタブ [19章 §19.6、ステージ 4]。
//
//  **ライブラリの「片付けごと」を 1 か所に集める。** 旧 3 ウインドウ
//  （見つからないファイル §15.7／保管庫 §15.4／フォーマットに一致しない
//  ファイル §15.6）は、どれも「左＝ライブラリ一覧、右＝一覧と操作」という
//  同じ形をしていたのに別々のウインドウで、しかも**保管庫は入口ゼロ**
//  （Stage P の右クリック最小化で失われたまま）だった。
//
//  ## 未整理（旧「フォーマットに一致しないファイル」）はここに来ない
//  [UR3-01][UR3-02] により、**メインウインドウの中央ペインの一覧**へ移した
//  ——普段のファイル操作（リネーム・Quick Look・ラベル付け）がそのまま
//  使えることがあの機能の要点で、専用ウインドウはそれを妨げていた。
//
//  ## 重複タブは作らない［ユーザー判断、2026-08-29］
//  中央ペインの「重複のみを表示」[DU-11] が同じ一覧を出し、そちらはリネーム・
//  保管庫送りもできる。**同じものを 2 か所で見せない。**
//
//  ## シリーズの提案タブ（Stage 10 で追加）
//  §19.5 の提案一覧。**このタブだけ左ペインの件数が選択中のライブラリぶんしか
//  出ない**——提案は保存された行が無く、数えるには検出を走らせるしかない
//  （`SeriesSuggestionModel` の型注記に実測値がある）。
//
import Foundation
import QooKit

/// メンテナンスウインドウのタブ。
///
/// **`CaseIterable` の順序がそのままタブの並び順**になる。片付ける頻度が
/// 高い順に置く——見つからないファイルは走査のたびに増えうるが、保管庫は
/// 利用者が明示的に入れたものしか無い。
public enum MaintenanceTab: String, CaseIterable, Sendable, Identifiable {
    /// 見つからないファイル [OR-01][OR-04][15章 §15.7]。
    case orphans
    /// ファイルの保管庫 [FAW-01〜05][15章 §15.4]。
    case vault
    /// シリーズの提案 [SS-01〜08][19章 §19.5]。
    case seriesSuggestions

    public var id: String { rawValue }

    /// 文字列カタログの鍵。**旧ウインドウの題をそのまま流用する**——同じ
    /// 機能を指す語を新しく作ると、要件・記録・画面で語彙が割れる
    /// （§15.7 の「見つからないファイル」で一度整理した語である）。
    public var titleKey: String {
        switch self {
        case .orphans: "orphanCleanup.windowTitle"
        case .vault: "fileVault.windowTitle"
        case .seriesSuggestions: "seriesSuggestions.title"
        }
    }

    public var systemImage: String {
        switch self {
        case .orphans: "questionmark.folder"
        case .vault: "archivebox"
        case .seriesSuggestions: "books.vertical"
        }
    }

    /// 左ペインの 1 行に出す状態。
    ///
    /// **タブによって「オフラインをどう扱うか」が違う**ので、ここで吸収する
    /// ——孤立は実体についての判断なので**オフラインでは件数を出さない**
    /// [OR2-06]（0 件と紛らわしい。「無い」のか「見られない」のかは別のこと）。
    /// 保管庫は DB だけで答えられるので件数を出し、操作だけを無効にする
    /// [SB-05]。
    ///
    /// **この差を統合の都合で揃えてはならない**——形が同じでも守っているものが
    /// 違う（このリポジトリが「前例を写すとき、何によって守られているかまで
    /// 写す」で繰り返し踏んでいる形）。
    public struct LibraryStatus: Sendable, Hashable {
        /// 件数。`showsCount` が偽のときは意味を持たない。
        public let count: Int
        /// 件数を出してよいか。
        public let showsCount: Bool
        /// 「オフライン」の注記を出すか。
        public let showsOfflineNote: Bool
        /// 行を淡く描くか（＝片付けるものが無い、または見られない）。
        public let isDimmed: Bool
        /// 行のアイコン。**タブごとに決める**——「件数が出せない」の理由が
        /// タブによって違う（孤立はオフライン、提案は数えていないだけ）ので、
        /// 同じ見た目にすると別のことを同じ絵で伝えることになる。
        public let iconName: String

        public init(count: Int, showsCount: Bool, showsOfflineNote: Bool, isDimmed: Bool,
                    iconName: String) {
            self.count = count
            self.showsCount = showsCount
            self.showsOfflineNote = showsOfflineNote
            self.isDimmed = isDimmed
            self.iconName = iconName
        }
    }

    /// - Parameters:
    ///   - counts: このタブの件数表（`orphanedFileCounts()` /
    ///     `archivedFileCounts()` の結果）。0 件はキーごと現れない。
    ///     **シリーズの提案だけは選択中のライブラリぶんしか入らない**ので、
    ///     キーが無いことが「0 件」ではなく「数えていない」を意味する。
    public func status(for library: LibrarySummary, counts: [LibraryID: Int]) -> LibraryStatus {
        let count = counts[library.id] ?? 0
        switch self {
        case .orphans:
            // `OrphanCleanupModel.canListOrphans(of:)` と同じ判定に乗る
            // ——2 箇所に書くと「一覧は出ないのに件数だけ出る」形でずれる。
            let listable = OrphanCleanupModel.canListOrphans(of: library)
            return LibraryStatus(count: count,
                                 showsCount: listable,
                                 showsOfflineNote: !listable,
                                 isDimmed: !listable || count == 0,
                                 iconName: listable && count > 0
                                     ? systemImage : "externaldrive.badge.xmark")
        case .vault:
            return LibraryStatus(count: count,
                                 showsCount: true,
                                 showsOfflineNote: !library.isOnline,
                                 isDimmed: count == 0,
                                 iconName: count > 0 ? systemImage
                                                     : "externaldrive.badge.xmark")
        case .seriesSuggestions:
            // **キーが無い＝数えていない。** オフラインの印は出さない
            // ——提案は DB だけで作れるので、ボリュームの有無と関係が無い。
            let counted = counts[library.id] != nil
            return LibraryStatus(count: count,
                                 showsCount: counted,
                                 showsOfflineNote: false,
                                 isDimmed: !counted || count == 0,
                                 iconName: systemImage)
        }
    }
}
