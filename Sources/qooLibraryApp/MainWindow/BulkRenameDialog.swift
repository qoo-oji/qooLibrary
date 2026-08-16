import QooKit
import SwiftUI

/// Finder の「名前を変更…」（複数選択時）相当 [ユーザー要望]。
///
/// **Finder には無いプレビューを付けている** [BR-08]。Finder は結果を見せずに
/// 実行するが、一括で名前を書き換える操作は取り返しの印象が強く、実行前に
/// 「変更前 → 変更後」を確かめられる方が安心して押せる。衝突する行は赤字で
/// 示し、1 件でもあれば実行させない [BR-09]。
///
/// Finder の `BulkRenameWindow` と同じく独立したウインドウとして出す
/// （`DialogWindowPresenter` 参照）。ウインドウのタイトルは提示側が組み立てる
/// ため、ここでは見出しを描かない。
struct BulkRenameDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dialogDismiss) private var dismiss

    /// ウインドウのタイトル。件数を含むため提示側と同じ組み立てをここに置き、
    /// 文言が 2 か所へ散らないようにする。
    static func windowTitle(count: Int, locale: Locale) -> String {
        String(format: String(localized: "bulkRename.title", locale: locale), count)
    }

    let names: [String]
    /// 同じフォルダにある「対象外」の項目の名前。衝突判定に使う。
    let existingNames: Set<String>
    let onCommit: ([BulkRename.Change]) -> Void

    @State private var mode: ModeSelection = .replaceText
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var addText = ""
    @State private var addPlacement: BulkRename.Placement = .after
    @State private var formatStyle = BulkRename.defaultFormatStyle
    @State private var formatCustomText = ""
    @State private var formatPlacement: BulkRename.Placement = .after
    @State private var startNumber = 1
    @State private var digits = BulkRename.defaultDigits
    @State private var separator = BulkRename.defaultSeparator
    @State private var replacesOriginalName = false

    private enum ModeSelection: String, CaseIterable, Identifiable {
        case replaceText, addText, format
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .replaceText: "bulkRename.mode.replaceText"
            case .addText: "bulkRename.mode.addText"
            case .format: "bulkRename.mode.format"
            }
        }
    }

    private var currentMode: BulkRename.Mode {
        switch mode {
        case .replaceText: .replaceText(find: findText, replaceWith: replaceText)
        case .addText: .addText(addText, placement: addPlacement)
        case .format: .format(
            style: formatStyle,
            customText: replacesOriginalName ? formatCustomText : nil,
            placement: formatPlacement, startNumber: startNumber,
            digits: digits, separator: separator
        )
        }
    }

    private var changes: [BulkRename.Change] {
        BulkRename.plan(names: names, mode: currentMode, existingNames: existingNames, locale: locale)
    }

    private var hasConflict: Bool { changes.contains { $0.conflicts } }
    private var hasAnyChange: Bool { changes.contains { $0.isChanged } }

    var body: some View {
        DialogScaffold(
            width: 620,
            confirm: DialogButton(title: String(localized: "bulkRename.rename", locale: locale)) {
                // 先に閉じてから実行する（`NameInputDialog.commit()` と同じ順序）。
                let planned = changes
                dismiss()
                onCommit(planned)
            },
            cancel: DialogButton(
                title: String(localized: "common.cancel", locale: locale), role: .cancel
            ) { dismiss() },
            // [BR-09] 衝突が 1 件でもあれば実行させない。
            confirmDisabled: hasConflict || !hasAnyChange
        ) {
            Picker("bulkRename.mode", selection: $mode) {
                ForEach(ModeSelection.allCases) { Text($0.titleKey).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            controls

            Divider()
            Text("bulkRename.preview")
                .font(.system(size: Tokens.fontSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            previewTable

            if hasConflict {
                Label("bulkRename.conflictWarning", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Colors.dangerText)
                    .font(.system(size: Tokens.fontSize.caption))
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch mode {
        case .replaceText:
            LabeledContent("bulkRename.find") { editableField($findText) }
            LabeledContent("bulkRename.replaceWith") { editableField($replaceText) }
        case .addText:
            LabeledContent("bulkRename.text") { editableField($addText) }
            Picker("bulkRename.placement", selection: $addPlacement) {
                Text("bulkRename.placement.before").tag(BulkRename.Placement.before)
                Text("bulkRename.placement.after").tag(BulkRename.Placement.after)
            }
            .pickerStyle(.radioGroup)
        case .format:
            Picker("bulkRename.formatStyle", selection: $formatStyle) {
                // 並びも既定も「番号のみ」が先頭［ユーザー要望］。
                Text("bulkRename.style.numberOnly").tag(BulkRename.FormatStyle.numberOnly)
                Text("bulkRename.style.index").tag(BulkRename.FormatStyle.nameAndIndex)
                Text("bulkRename.style.date").tag(BulkRename.FormatStyle.nameAndDate)
            }
            // 「番号のみ」は元の名前もカスタム文字列も使わないので、
            // 名前まわりの設定は出さない（効かない設定を見せない）。
            if formatStyle != .numberOnly {
                // 置き換えるかどうかを明示させる［ユーザー要望］。以前は
                // 「空欄なら元の名前」という暗黙の規則で、空欄の意味が
                // 2 通りに読めた。チェックが off の間は欄自体を触れなくする。
                Toggle("bulkRename.replaceOriginalName", isOn: $replacesOriginalName)
                LabeledContent("bulkRename.customFormat") {
                    editableField($formatCustomText)
                        .disabled(!replacesOriginalName)
                        .opacity(replacesOriginalName ? 1 : 0.4)
                }
                Picker("bulkRename.placement", selection: $formatPlacement) {
                    Text("bulkRename.placement.before").tag(BulkRename.Placement.before)
                    Text("bulkRename.placement.after").tag(BulkRename.Placement.after)
                }
                .pickerStyle(.radioGroup)
                Picker("bulkRename.separator", selection: $separator) {
                    Text("bulkRename.separator.underscore").tag(BulkRename.Separator.underscore)
                    Text("bulkRename.separator.hyphen").tag(BulkRename.Separator.hyphen)
                    Text("bulkRename.separator.space").tag(BulkRename.Separator.space)
                    Text("bulkRename.separator.none").tag(BulkRename.Separator.none)
                }
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)
            }
            if formatStyle != .nameAndDate {
                LabeledContent("bulkRename.startNumber") {
                    TextField("", value: $startNumber, format: .number)
                        .editableFieldChrome()
                        .frame(width: 80)
                }
                // 桁数（ゼロ詰め）［ユーザー要望］。数を打たせるより、
                // 実際にどう出るか（1 / 01 / 001 …）を並べて選ばせる方が速い。
                Picker("bulkRename.digits", selection: $digits) {
                    ForEach(Array(BulkRename.digitRange), id: \.self) { width in
                        Text(String(format: "%0\(width)d", 1)).tag(width)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .leading)
            }
        }
    }

    private func editableField(_ text: Binding<String>) -> some View {
        TextField("", text: text).editableFieldChrome()
    }

    private var previewTable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(changes) { change in
                    HStack(spacing: Tokens.spacing.s) {
                        Text(change.originalName)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        Text(change.newName)
                            // [BR-09] 衝突する行は赤字。
                            .foregroundStyle(change.conflicts ? Tokens.Colors.dangerText : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: Tokens.fontSize.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .padding(Tokens.spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 180)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius.s))
    }
}

/// 一括リネーム 1 回分の対象。対象の収集（兄弟一覧の読み取り）が非同期なので、
/// 集め終えてからダイアログを出すまでの受け渡しに使う。
struct PendingBulkRename {
    let folder: URL
    let names: [String]
    let existingNames: Set<String>
}
