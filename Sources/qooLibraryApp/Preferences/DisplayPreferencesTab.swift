import QooApplication
import SwiftUI

/// 名前列（中央ペイン `Table`）の省略位置 [ユーザー要望]。`Text` の
/// `truncationMode(_:)` にそのまま対応する3値。`String` を rawValue に
/// しているのは `ListStyle` と同じ理由（`@AppStorage` で直接扱うため）。
public enum NameTruncationMode: String, Sendable, Equatable, CaseIterable {
    case head, middle, tail

    var swiftUIMode: Text.TruncationMode {
        switch self {
        case .head: return .head
        case .middle: return .middle
        case .tail: return .tail
        }
    }
}

/// 環境設定「表示」タブ [15.10 節]。新規ウインドウ/タブを開いたときの既定
/// 表示モード・アイコンサイズと、リスト表示のカラム表示/非表示 [LV-02] を
/// まとめる。
///
/// 既定表示モード・アイコンサイズは新規（`WindowState.init()` が読む）の
/// `UserDefaults` キー。カラム表示/非表示は既存のキーをそのまま参照する
/// （中央ペインの漏斗アイコンメニューにも同じ設定への quick access があるが、
/// Finder の「表示オプション」相当の頻用操作として引き続き残している。
/// こちらはその設定の集約先）。カラム名（`column.*`）は `FolderContentView.swift`
/// の漏斗アイコンメニュー・テーブルヘッダ・並び替えメニューと同じキーを
/// 共有している。
struct DisplayPreferencesTab: View {
    @AppStorage("qoo.preferences.defaultListStyle") private var defaultListStyle: ListStyle = .list
    @AppStorage("qoo.preferences.defaultIconSize") private var defaultIconSize: Double = 96
    /// [LV-03] 「一般」タブから移設した（ユーザー指摘: 表示に関する設定のため）。
    @AppStorage("qoo.folderList.groupFoldersAtTop") private var groupFoldersAtTop = true
    @AppStorage("qoo.folderList.showModificationDateColumn") private var showModificationDateColumn = true
    @AppStorage("qoo.folderList.showSizeColumn") private var showSizeColumn = true
    @AppStorage("qoo.folderList.showKindColumn") private var showKindColumn = true
    // Finder の列選択に合わせて追加した2列 [ユーザー要望]。既定は非表示
    // （`FolderContentView.swift` の同名プロパティのコメント参照）。
    @AppStorage("qoo.folderList.showCreationDateColumn") private var showCreationDateColumn = false
    @AppStorage("qoo.folderList.showAddedDateColumn") private var showAddedDateColumn = false
    /// [ユーザー要望] `FolderTreePane` と同じキーを共有する。
    @AppStorage("qoo.preferences.autoExpandTreeToCurrentFolder") private var autoExpandTreeToCurrentFolder = true
    /// [ユーザー要望] `FolderContentView.swift` の名前列（`Table`）と同じ
    /// キーを共有する。
    @AppStorage("qoo.folderList.nameTruncationMode") private var nameTruncationMode: NameTruncationMode = .tail

    /// 左ペイン「よく使う項目」に並べる場所 [ユーザー要望、Finder の
    /// 「サイドバーに表示する項目」相当]。
    ///
    /// **`@AppStorage` を 8 個並べない。** キーが項目ごとに動的で
    /// （`FavoriteLocations.storageKey`）、既定値も項目によって違うため、
    /// 素直には書けない。読み書きは `FavoriteLocations` に集約し、ここは
    /// 画面を描き直すための写しだけを持つ——**既定値の判断を 2 か所に
    /// 置かない**のが要点。
    @State private var visibleFavorites: Set<StandardLocation> = []

    var body: some View {
        Form {
            Section {
                Picker("preferences.display.defaultDisplayMode", selection: $defaultListStyle) {
                    Text("common.list").tag(ListStyle.list)
                    Text("common.icon").tag(ListStyle.icon)
                }
                HStack {
                    Text("preferences.display.defaultIconSize")
                    Slider(value: $defaultIconSize, in: Tokens.iconSize.min...Tokens.iconSize.max, step: Tokens.iconSize.step)
                }
                Toggle("preferences.general.groupFoldersAtTop", isOn: $groupFoldersAtTop) // [LV-03]
                Toggle("preferences.display.autoExpandTree", isOn: $autoExpandTreeToCurrentFolder)
                Picker("preferences.display.nameTruncationMode", selection: $nameTruncationMode) {
                    Text("preferences.display.truncationHead").tag(NameTruncationMode.head)
                    Text("preferences.display.truncationMiddle").tag(NameTruncationMode.middle)
                    Text("preferences.display.truncationTail").tag(NameTruncationMode.tail)
                }
            }

            // 左ペイン「よく使う項目」に並べる場所 [ユーザー要望]。存在しない
            // フォルダ（`~/Movies` を消している等）はチェックしても行が出ない
            // ——`FavoriteLocations.load` が実体のあるものだけを並べる。
            Section {
                ForEach(FavoriteLocations.candidates) { location in
                    Toggle(location.titleKey, isOn: Binding(
                        get: { visibleFavorites.contains(location) },
                        set: { isOn in
                            FavoriteLocations.setVisible(location, isOn)
                            visibleFavorites = Set(FavoriteLocations.visible)
                            // 左ペインへ即座に反映する（登録フォルダの増減や
                            // アクセス許可の変化と同じ共通シグナル）。
                            SessionState.shared.reloadToken += 1
                        }
                    ))
                }
            } header: {
                Text("preferences.display.favoritesHeader")
            }

            Section {
                Toggle("column.modificationDate", isOn: $showModificationDateColumn)
                Toggle("column.size", isOn: $showSizeColumn)
                Toggle("column.kind", isOn: $showKindColumn)
                Toggle("column.creationDate", isOn: $showCreationDateColumn)
                Toggle("column.addedDate", isOn: $showAddedDateColumn)
            } header: {
                Text("preferences.display.columnsHeader") // [LV-02]
            }

            // アイコンサイズはスライダーで既定値が分かりにくいため
            // [ユーザー指摘: 調整系の設定には必ず「既定に戻す」を付けること]。
            Section {
                Button("preferences.resetToDefaults") {
                    defaultListStyle = .list
                    defaultIconSize = 96
                    groupFoldersAtTop = true
                    autoExpandTreeToCurrentFolder = true
                    nameTruncationMode = .tail
                    showModificationDateColumn = true
                    showSizeColumn = true
                    showKindColumn = true
                    showCreationDateColumn = false
                    showAddedDateColumn = false
                    FavoriteLocations.resetToDefaults()
                    visibleFavorites = Set(FavoriteLocations.visible)
                    SessionState.shared.reloadToken += 1
                }
            }
        }
        .formStyle(.grouped)
        .padding(Tokens.spacing.l)
        .task { visibleFavorites = Set(FavoriteLocations.visible) }
    }
}
