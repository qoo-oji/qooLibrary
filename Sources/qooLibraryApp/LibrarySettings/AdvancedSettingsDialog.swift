//
//  高度な設定 [§19.7][P3]。
//
//  通常時に見えるのは 4 セクションだけで、めったに触らない 6 つはこの
//  ダイアログの中にある。**登録ウィザードと設定ウインドウで同じものを開く**
//  ——同じ編集 UI を 2 つ持たない（このコードベースが「同じ機能に複数の
//  到達経路を作り、片方だけ直して取り残す」を繰り返し踏んでいるため）。
//
import QooApplication
import QooKit
import SwiftUI

// MARK: - セクション 1 つ分のエディタ

/// ダイアログの中に置けるセクションの中身。
///
/// **`.basics` も描ける**——登録ウィザードはこのダイアログの中でしか基本設定に
/// 触れないため（ステップ 4 は分類の設定に絞ってあり、ブックタイプ名や
/// 埋め込みメタデータの節を持たない）。設定ウインドウ側は中央ペインに基本の
/// 行があるので、`sections` に含めずに開く。
///
/// 描けないのは `filenameFormats`（選択中のフォーマットとサンプル文字列を
/// 呼び出し側が保持する必要がある）と `fields`／`folderLevels`——
/// いずれも通常セクションなので、高度なダイアログには現れない。`switch` は
/// 全 case を書いておく（`default` にすると、セクションを足したときに
/// コンパイラが指摘してくれなくなる）。
struct AdvancedSectionEditor: View {
    let section: LibrarySettingsSection
    @Binding var draft: LibrarySettingsDraft

    var body: some View {
        switch section {
        case .basics:            LibraryBasicsSettingsView(draft: $draft)
        case .extensions:        LibraryExtensionsSettingsView(draft: $draft)
        case .volumeFormats:     LibraryVolumeFormatsSettingsView(draft: $draft)
        case .seriesTitle:       LibrarySeriesTitleSettingsView(draft: $draft)
        case .delimiters:        LibraryDelimitersSettingsView(draft: $draft)
        case .protectedTokens:   LibraryProtectedTokensSettingsView(draft: $draft)
        case .bookFolderOpening: LibraryBookFolderOpeningSettingsView(draft: $draft)
        case .fields, .folderLevels, .filenameFormats: EmptyView()
        }
    }
}

// MARK: - 高度な設定の本体（左リスト＋右エディタ）

/// ダイアログの中身。**殻を持たない**ので、ウィザード（プレビュー付き）と
/// 設定ウインドウ（プレビュー無し）が同じものを別の枠に載せられる。
struct AdvancedSettingsEditor: View {
    /// 登録ウィザードから開くときに並べるもの。**基本設定を先頭に足す**
    /// ——ウィザードのステップ 4 は分類の設定に絞ってあり、ブックタイプ名・
    /// 重複のまとめ方・埋め込みメタデータに触れる場所がここしかない。
    static let wizardSections: [LibrarySettingsSection] =
        [.basics] + LibrarySettingsSection.advanced

    @Binding var draft: LibrarySettingsDraft
    let sections: [LibrarySettingsSection]
    @State private var section: LibrarySettingsSection

    /// `initialSection` は「不備の行から開かれた」ときに、その設定を最初から
    /// 見せるために使う。並べないものを渡されても意味が無いので先頭へ落とす。
    init(draft: Binding<LibrarySettingsDraft>,
         sections: [LibrarySettingsSection] = LibrarySettingsSection.advanced,
         initialSection: LibrarySettingsSection? = nil) {
        self._draft = draft
        self.sections = sections
        let start = initialSection.flatMap { sections.contains($0) ? $0 : nil }
        self._section = State(initialValue: start ?? sections[0])
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(sections) { section in
                    Label {
                        Text(section.titleKey)
                    } icon: {
                        Image(systemName: section.systemImage)
                    }
                    .tag(section)
                }
            }
            .frame(width: 210)
            Divider()
            ScrollView {
                AdvancedSectionEditor(section: section, draft: $draft)
                    .padding(Tokens.spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - 設定ウインドウから開くダイアログ

/// 設定ウインドウの「高度な設定…」[§19.7]。
///
/// **草案を編集するだけで、保存はしない**——閉じても設定ウインドウの「保存」を
/// 押すまで DB には何も書かない（現行の settingsRevision 経路をそのまま保つ
/// [RG3-27]）。閉じるボタンが「完了」なのはそのため。取り消したければ
/// 設定ウインドウの「変更を戻す」を押す。
struct AdvancedSettingsDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    @Binding var draft: LibrarySettingsDraft
    var initialSection: LibrarySettingsSection?

    var body: some View {
        VStack(spacing: 0) {
            AdvancedSettingsEditor(draft: $draft, initialSection: initialSection)
            Divider()
            QooDialogFooter(
                confirm: DialogButton(
                    title: String(localized: "librarySettings.advanced.done", locale: locale)
                ) { dismiss() },
                cancel: nil)
                .padding(Tokens.spacing.m)
        }
        .frame(width: 880, height: 560)
    }
}
