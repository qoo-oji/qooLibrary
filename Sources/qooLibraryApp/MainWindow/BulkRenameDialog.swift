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
            // 空欄は「元のファイル名を使う」（nil）。Finder のカスタム
            // フォーマットと同じ動作［ユーザー要望でチェック方式から戻した］。
            customText: formatCustomText.isEmpty ? nil : formatCustomText,
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
            // モード切替はウインドウの中央に置く［ユーザー指摘: 左寄せは
            // 違和感がある］。`maxWidth: .infinity` の既定アラインメントが
            // 中央なので、これだけで内容サイズのまま中央に寄る。
            .frame(maxWidth: .infinity)

            // モード切替と操作部の区切り［ユーザー要望］。プレビュー側は
            // テーブル自身がヘッダ行を持つため、見出し文字と区切り線は
            // 置かない（同じくユーザー要望で撤去）。
            Divider()

            controls

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
            // 選択肢 2 つを縦に積まず横に並べる［ユーザー指摘: 横方向に
            // スペースが空いているのに縦に積む理由が無い］。
            .horizontalRadioGroupLayout()
        case .format:
            HStack(spacing: Tokens.spacing.s) {
                // ラベルを Picker に描かせず自前で出し、「位置」「開始番号」と
                // 右端を揃える［ユーザー要望］。
                Text("bulkRename.formatStyle")
                    .frame(width: formatLeadingLabelWidth, alignment: .trailing)
                // 「開始番号」の入力ボックスと幅を揃えるため `FixedWidthPopUp`
                // ［ユーザー要望。並びも既定も「番号のみ」が先頭という以前の
                // 要望はそのまま］。
                FixedWidthPopUp(
                    items: [
                        .init(title: String(localized: "bulkRename.style.numberOnly", locale: locale), tag: BulkRename.FormatStyle.numberOnly),
                        .init(title: String(localized: "bulkRename.style.index", locale: locale), tag: BulkRename.FormatStyle.nameAndIndex),
                        .init(title: String(localized: "bulkRename.style.date", locale: locale), tag: BulkRename.FormatStyle.nameAndDate),
                    ],
                    selection: $formatStyle
                )
                .frame(width: formatStyleControlWidth)
                Spacer(minLength: 0)
            }
            // 「番号のみ」は元の名前もカスタム文字列も使わないので、
            // 名前まわりの設定は出さない（効かない設定を見せない）。
            if formatStyle != .numberOnly {
                // 空欄なら元のファイル名、入力があればその文字列へ置き換える
                // — Finder の「カスタムフォーマット」と同じ動作［ユーザー要望。
                // 一時期あった「元のファイル名を…置き換える」チェックは廃止し、
                // この元の形へ戻した］。ラベルは他の行と右端を揃える。
                HStack(spacing: Tokens.spacing.s) {
                    Text("bulkRename.customFormat")
                        .frame(width: formatLeadingLabelWidth, alignment: .trailing)
                    editableField($formatCustomText)
                }
                // 「位置」と「区切り文字」は 1 行にまとめる［ユーザー要望:
                // 横方向にスペースが空いているのに縦に積む理由が無い］。
                // カラムの揃え方は `formatLeadingColumnWidth` のコメント参照。
                HStack(spacing: Tokens.spacing.s) {
                    HStack(spacing: Tokens.spacing.s) {
                        // ラベルは Picker に描かせず自前で出す — 「開始番号」と
                        // 右端を揃えるため（右寄せの固定幅ラベル列）［ユーザー要望］。
                        Text("bulkRename.placement")
                            .frame(width: formatLeadingLabelWidth, alignment: .trailing)
                        Picker("bulkRename.placement", selection: $formatPlacement) {
                            Text("bulkRename.placement.before").tag(BulkRename.Placement.before)
                            Text("bulkRename.placement.after").tag(BulkRename.Placement.after)
                        }
                        .pickerStyle(.radioGroup)
                        // 「テキストを追加」の位置指定と同じ理由で横並びにする。
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.formatLeadingColumnWidth, alignment: .leading)
                    Text("bulkRename.separator")
                        .frame(width: formatSecondLabelWidth, alignment: .trailing)
                    // メニュー式 `Picker` ではなく `FixedWidthPopUp` を使う —
                    // Picker は `.frame` で幅を固定できず、「桁数」との幅が
                    // 揃わない（`FixedWidthPopUp` のコメント参照）。
                    FixedWidthPopUp(
                        items: [
                            .init(title: String(localized: "bulkRename.separator.underscore", locale: locale), tag: BulkRename.Separator.underscore),
                            .init(title: String(localized: "bulkRename.separator.hyphen", locale: locale), tag: BulkRename.Separator.hyphen),
                            .init(title: String(localized: "bulkRename.separator.space", locale: locale), tag: BulkRename.Separator.space),
                            .init(title: String(localized: "bulkRename.separator.none", locale: locale), tag: BulkRename.Separator.none),
                        ],
                        selection: $separator,
                        titleAlignment: .right // 表示値は右揃え［ユーザー要望］
                    )
                    .frame(width: Self.formatPopupWidth)
                    Spacer(minLength: 0)
                }
            }
            if formatStyle != .nameAndDate {
                // 「開始番号」と「桁数」も 1 行にまとめる（同上）。
                HStack(spacing: Tokens.spacing.s) {
                    HStack(spacing: Tokens.spacing.s) {
                        Text("bulkRename.startNumber")
                            .frame(width: formatLeadingLabelWidth, alignment: .trailing)
                        TextField("", value: $startNumber, format: .number)
                            .editableFieldChrome()
                            .multilineTextAlignment(.trailing) // 数値は右揃え［ユーザー要望］
                            // 「名前の形式」のドロップダウンと同幅［ユーザー要望］。
                            .frame(width: formatStyleControlWidth)
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.formatLeadingColumnWidth, alignment: .leading)
                    Text("bulkRename.digits")
                        .frame(width: formatSecondLabelWidth, alignment: .trailing)
                    // 桁数（ゼロ詰め）［ユーザー要望］。数を打たせるより、
                    // 実際にどう出るか（1 / 01 / 001 …）を並べて選ばせる方が速い。
                    // 「区切り文字」と幅を揃えるため `FixedWidthPopUp`（同上）。
                    FixedWidthPopUp(
                        items: BulkRename.digitRange.map { width in
                            .init(title: String(format: "%0\(width)d", 1), tag: width)
                        },
                        selection: $digits,
                        titleAlignment: .right // 表示値は右揃え［ユーザー要望］
                    )
                    .frame(width: Self.formatPopupWidth)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 高度なリネームの 2 行（位置＋区切り文字／開始番号＋桁数）を、モードに
    /// よらず同じ位置へ揃えるための固定カラム幅［ユーザー要望: 各ラベルの
    /// 文字列の右端を上下で揃え、ドロップダウンの幅も揃える。行が 1 本しか
    /// 出ないモード（番号のみ・名前と日付）でも同じ配置にする］。
    /// 行の構成: 左ブロック（ラベル右寄せ＋コントロール、全体は固定幅で
    /// 左寄せ）→ 第 2 ラベル（右寄せ・固定幅）→ ドロップダウン（固定幅）。
    /// 左ブロックの固定幅が「名前の後」と「区切り文字」の間の余白も作る。
    private static let formatLeadingColumnWidth: CGFloat = 250
    private static let formatPopupWidth: CGFloat = 160

    /// ラベル列の幅はロケールの実測から採る（ja と en で必要幅が大きく違い、
    /// 固定値だとどちらかで切り詰められるため）。+4pt は `Text` の実描画が
    /// `NSString` 計測をわずかに上回ったときの切り詰め（`…`）を防ぐ余裕。
    private var formatLeadingLabelWidth: CGFloat {
        DialogButtonMetrics.maxLabelWidth([
            String(localized: "bulkRename.formatStyle", locale: locale),
            String(localized: "bulkRename.customFormat", locale: locale),
            String(localized: "bulkRename.placement", locale: locale),
            String(localized: "bulkRename.startNumber", locale: locale),
        ]) + 4
    }

    /// 「名前の形式」のドロップダウンと「開始番号」の入力ボックスの共通幅
    /// ［ユーザー要望: 両者の幅を揃える］。ドロップダウン側が切り詰めなく
    /// 表示できる幅（最長項目の実測 + ポップアップの左右余白・シェブロン分）
    /// を基準にする。
    private var formatStyleControlWidth: CGFloat {
        DialogButtonMetrics.maxLabelWidth([
            String(localized: "bulkRename.style.numberOnly", locale: locale),
            String(localized: "bulkRename.style.index", locale: locale),
            String(localized: "bulkRename.style.date", locale: locale),
        ]) + 44
    }

    private var formatSecondLabelWidth: CGFloat {
        DialogButtonMetrics.maxLabelWidth([
            String(localized: "bulkRename.separator", locale: locale),
            String(localized: "bulkRename.digits", locale: locale),
        ]) + 4
    }

    private func editableField(_ text: Binding<String>) -> some View {
        TextField("", text: text).editableFieldChrome()
    }

    private var previewTable: some View {
        // 2 列の実テーブル［ユーザー要望］。長いファイル名はこのスペースに
        // 収まらないことがあり、フルネームを確かめる手段が無いとプレビューとして
        // 機能しない。`Table`（NSTableView 由来）はヘッダの区切り線のドラッグに
        // よる列幅調整を標準で持つため、自前のリストから置き換えた。
        // 中央省略で収まらない場合の補助としてツールチップにもフルネームを出す。
        // ヘッダ（変更前／変更後）は各列の中央に置く［ユーザー要望］。
        // `alignment(.center)` は列全体（ヘッダとセル）の揃えなので、
        // セル側には明示的な leading の frame を与えて名前は左揃えのまま保つ。
        Table(changes) {
            TableColumn("bulkRename.column.original") { change in
                Text(change.originalName)
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(change.originalName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alignment(.center)
            TableColumn("bulkRename.column.new") { change in
                Text(change.newName)
                    // [BR-09] 衝突する行は赤字。
                    .font(.system(size: Tokens.fontSize.caption))
                    .foregroundStyle(change.conflicts ? Tokens.Colors.dangerText : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(change.newName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alignment(.center)
        }
        .frame(height: 180)
    }
}

/// 一括リネーム 1 回分の対象。対象の収集（兄弟一覧の読み取り）が非同期なので、
/// 集め終えてからダイアログを出すまでの受け渡しに使う。
struct PendingBulkRename {
    let folder: URL
    let names: [String]
    let existingNames: Set<String>
}
