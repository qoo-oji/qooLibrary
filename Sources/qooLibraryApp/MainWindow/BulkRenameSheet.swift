import QooKit
import SwiftUI

/// Finder の「名前を変更…」（複数選択時）相当 [ユーザー要望]。
///
/// **Finder には無いプレビューを付けている** [BR-08]。Finder は結果を見せずに
/// 実行するが、一括で名前を書き換える操作は取り返しの印象が強く、実行前に
/// 「変更前 → 変更後」を確かめられる方が安心して押せる。衝突する行は赤字で
/// 示し、1 件でもあれば実行させない [BR-09]。
struct BulkRenameSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let names: [String]
    /// 同じフォルダにある「対象外」の項目の名前。衝突判定に使う。
    let existingNames: Set<String>
    let onCommit: ([BulkRename.Change]) -> Void

    @State private var mode: ModeSelection = .replaceText
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var addText = ""
    @State private var addPlacement: BulkRename.Placement = .after
    @State private var formatStyle: BulkRename.FormatStyle = .nameAndIndex
    @State private var formatCustomText = ""
    @State private var formatPlacement: BulkRename.Placement = .after
    @State private var startNumber = 1

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
            style: formatStyle, customText: formatCustomText,
            placement: formatPlacement, startNumber: startNumber
        )
        }
    }

    private var changes: [BulkRename.Change] {
        BulkRename.plan(names: names, mode: currentMode, existingNames: existingNames, locale: locale)
    }

    private var hasConflict: Bool { changes.contains { $0.conflicts } }
    private var hasAnyChange: Bool { changes.contains { $0.isChanged } }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing.m) {
            Text(String(format: String(localized: "bulkRename.title", locale: locale), names.count))
                .font(.system(size: Tokens.fontSize.title2, weight: .semibold))

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

            QooDialogFooter(
                confirm: DialogButton(title: String(localized: "bulkRename.rename", locale: locale)) {
                    onCommit(changes)
                    dismiss()
                },
                cancel: DialogButton(title: String(localized: "common.cancel", locale: locale), role: .cancel) {
                    dismiss()
                },
                // [BR-09] 衝突が 1 件でもあれば実行させない。
                confirmDisabled: hasConflict || !hasAnyChange
            )
        }
        .padding(Tokens.spacing.l)
        .frame(width: 620)
    }

    @ViewBuilder
    private var controls: some View {
        switch mode {
        case .replaceText:
            LabeledContent("bulkRename.find") { TextField("", text: $findText) }
            LabeledContent("bulkRename.replaceWith") { TextField("", text: $replaceText) }
        case .addText:
            LabeledContent("bulkRename.text") { TextField("", text: $addText) }
            Picker("bulkRename.placement", selection: $addPlacement) {
                Text("bulkRename.placement.before").tag(BulkRename.Placement.before)
                Text("bulkRename.placement.after").tag(BulkRename.Placement.after)
            }
            .pickerStyle(.radioGroup)
        case .format:
            Picker("bulkRename.formatStyle", selection: $formatStyle) {
                Text("bulkRename.style.index").tag(BulkRename.FormatStyle.nameAndIndex)
                Text("bulkRename.style.counter").tag(BulkRename.FormatStyle.nameAndCounter)
                Text("bulkRename.style.date").tag(BulkRename.FormatStyle.nameAndDate)
            }
            LabeledContent("bulkRename.customFormat") { TextField("", text: $formatCustomText) }
            Picker("bulkRename.placement", selection: $formatPlacement) {
                Text("bulkRename.placement.before").tag(BulkRename.Placement.before)
                Text("bulkRename.placement.after").tag(BulkRename.Placement.after)
            }
            .pickerStyle(.radioGroup)
            if formatStyle != .nameAndDate {
                LabeledContent("bulkRename.startNumber") {
                    TextField("", value: $startNumber, format: .number).frame(width: 80)
                }
            }
        }
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

/// 一括リネームの保留状態。`.sheet(item:)` に渡す。
struct PendingBulkRename: Identifiable {
    let id = UUID()
    let folder: URL
    let names: [String]
    let existingNames: Set<String>
}
