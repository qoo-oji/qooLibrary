//
//  差分の適用 [LT-14][LT-16]。**純粋関数**（`QooKit`）。
//
//  選んだ項目だけを草案へ写す。**全適用の口は作らない** [LT-14] ので、
//  ここも「項目の配列」しか受け取らない——`applyAll()` を足したくなったら、
//  それは要件に反していないか先に確かめること。
//
//  適用の結果は `updateSettings(_:libraryID:)` へ渡す。取り消しは
//  **適用前の草案をそのまま書き戻す**（`ApplyTemplateDiffCommand`）ので、
//  ここが返す草案は「そのまま保存できる完全な設定」でなければならない。
//
import Foundation

extension TemplateDiff {

    /// 選んだ項目を草案へ適用する [LT-14]。
    ///
    /// **利用者が自分で足した項目は落とさない** [D3]。並べ替えは 3 者すべてに
    /// 在るフォーマットの位置だけを入れ替え、それ以外は元の位置に残す
    /// ——素直に「プリセットの並びで置き換える」と、利用者が足した
    /// フォーマットが消える（FileBot の「更新でプリセットが失われる」と同型）。
    public static func applying(_ items: [Item],
                                to draft: LibrarySettingsDraft) -> LibrarySettingsDraft
    {
        var result = draft
        for item in items {
            switch item.action {

            case let .addField(index, name, assignsAutomatically, bindings):
                guard !result.fields.contains(where: { $0.index == index }) else { continue }
                let colors = LabelColorPalette.palette(count: max(result.fields.count + 1, 1))
                let color = colors[min(result.fields.count, colors.count - 1)]
                result.fields.append(FieldDraft(
                    index: index, name: name,
                    colorHexLight: color.hexLight, colorHexDark: color.hexDark,
                    assignsAutomatically: assignsAutomatically))
                for keyword in bindings { result.semanticBindings[keyword] = index }

            case let .renameField(index, name):
                guard let position = result.fields.firstIndex(where: { $0.index == index })
                else { continue }
                result.fields[position].name = name

            case let .setFieldAutoAssign(index, value):
                guard let position = result.fields.firstIndex(where: { $0.index == index })
                else { continue }
                result.fields[position].assignsAutomatically = value

            case let .addFilenameFormat(source, after):
                guard !result.filenameFormats.contains(where: { $0.source == source })
                else { continue }
                let new = FilenameFormatDraft(source: source)
                if let after,
                   let anchor = result.filenameFormats.firstIndex(where: { $0.source == after }) {
                    result.filenameFormats.insert(new, at: anchor + 1)
                } else if after == nil {
                    result.filenameFormats.insert(new, at: 0)
                } else {
                    result.filenameFormats.append(new)
                }

            case let .removeFilenameFormat(source):
                result.filenameFormats.removeAll { $0.source == source }

            case let .reorderFilenameFormats(order):
                result.filenameFormats = reordered(result.filenameFormats, toMatch: order)

            case let .addVolumeFormat(source, kind):
                guard !result.volumeFormats.contains(where: {
                    $0.source == source && $0.kind == kind
                }) else { continue }
                result.volumeFormats.append(VolumeFormatDraft(source: source, kind: kind))

            case let .removeVolumeFormat(source, kind):
                result.volumeFormats.removeAll { $0.source == source && $0.kind == kind }

            case let .setFolderLevel(level, assignment):
                result.folderLevels.removeAll { $0.level == level }
                if let assignment {
                    result.folderLevels.append(
                        FolderLevelDraft(level: level, assignment: assignment))
                    result.folderLevels.sort { $0.level < $1.level }
                }
            }
        }
        return result
    }

    /// `order` に載っているフォーマットだけを、その相対順へ並べ替える。
    /// **載っていないものは元の位置に残す**——利用者が足したフォーマットの
    /// 優先順を、こちらの都合で動かさないため。
    private static func reordered(_ formats: [FilenameFormatDraft],
                                  toMatch order: [String]) -> [FilenameFormatDraft]
    {
        let targets = Set(order)
        // 並べ替える対象を、`order` の順に取り出しておく。
        var queue: [FilenameFormatDraft] = []
        for source in order {
            if let match = formats.first(where: { $0.source == source }) { queue.append(match) }
        }
        guard queue.count > 1 else { return formats }
        var cursor = 0
        return formats.map { format in
            guard targets.contains(format.source), cursor < queue.count else { return format }
            defer { cursor += 1 }
            return queue[cursor]
        }
    }
}
