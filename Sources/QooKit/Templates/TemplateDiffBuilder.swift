//
//  差分の組み立て [LT-13][LT-15]。**純粋関数**（`QooKit`）。
//
//  ## 項目の同一性はソース文字列の完全一致で決める［ユーザー判断］
//  ファイル名・巻数フォーマットは id を持たない順序付きリストなので、
//  「同じ項目」を決める手がかりがソース文字列しか無い。一致しなければ
//  **「追加」と「削除」に割り、「変更」を作らない**。
//
//  位置（配列の添字）で同定する案は採らなかった——プリセットが先頭に 1 本
//  挿しただけで**以降すべてが「変更」になる**（Salesforce のメタデータで
//  実際に起きている偽の衝突と同型）。正規化して同定する案も採らない——
//  フォーマットの空白は弾力的空白 [WS-01〜07] として意味を持つので、
//  空白差を同一視すると別のフォーマットを同じものと見なしうる。
//
import Foundation

public enum TemplateDiffBuilder {

    /// 差分を組み立てる [LT-13]。
    ///
    /// - Parameters:
    ///   - base: そのライブラリが登録された時点のプリセット定義。
    ///   - latest: 最新のプリセット定義。
    ///   - current: ライブラリの現在の設定。
    public static func diff(base: LibraryTypeTemplate,
                            latest: LibraryTypeTemplate,
                            current: LibrarySettingsDraft,
                            volumeSets: VolumeSetDefinition) -> TemplateDiff
    {
        let baseDraft = TemplateInstantiation.draft(
            from: base, volumeSets: volumeSets, displayName: "")
        let newDraft = TemplateInstantiation.draft(
            from: latest, volumeSets: volumeSets, displayName: "")

        var items: [TemplateDiff.Item] = []
        items += fieldItems(base: base, latest: latest, current: current)
        items += filenameFormatItems(base: baseDraft, latest: newDraft, current: current)
        items += volumeFormatItems(base: baseDraft, latest: newDraft, current: current)
        items += folderLevelItems(base: baseDraft, latest: newDraft, current: current)

        return TemplateDiff(items: items,
                            fromVersion: base.version, toVersion: latest.version)
    }

    // MARK: - フィールド

    /// **追加と、名前・自動付与の変更だけ**を出す。削除を出さない理由は
    /// `TemplateDiff` の型コメント（ラベルが連鎖で消え、⌘Z で戻らない）。
    private static func fieldItems(base: LibraryTypeTemplate,
                                   latest: LibraryTypeTemplate,
                                   current: LibrarySettingsDraft) -> [TemplateDiff.Item]
    {
        var items: [TemplateDiff.Item] = []
        let baseByIndex = Dictionary(base.fields.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let currentByIndex = Dictionary(current.fields.map { ($0.index, $0) },
                                        uniquingKeysWith: { a, _ in a })
        let usedIndexes = Set(current.fields.map(\.index))
        let boundKeywords = Set(current.semanticBindings.keys)
        var claimed = usedIndexes

        for spec in latest.fields.sorted(by: { $0.index < $1.index }) {
            let bindings = latest.semanticKeywordBindings
                .filter { $0.value == spec.index }
                .map(\.key)
                .sorted { $0.rawValue < $1.rawValue }

            guard let baseSpec = baseByIndex[spec.index] else {
                // **プリセットが新しく持つようになったフィールド。**
                // 利用者が既に同じ意味のフィールドを持っているなら出さない
                // ——束縛が既にあれば、名前が違っても同じ軸である。
                if !bindings.isEmpty, bindings.allSatisfy({ boundKeywords.contains($0) }) { continue }
                if bindings.isEmpty, current.fields.contains(where: { $0.name == spec.name }) { continue }
                // 番号が埋まっていれば空いている番号へ置く。番号はフィールドの
                // 身元ではない [Stage 5] ので、束縛さえ正しければ意味は保たれる。
                //
                // **上限 [AL-05] を超えるなら、この項目は出さない。** 出しても
                // 草案の検証が通らず、`updateSettings` が投げて**同時に選んだ
                // 他の項目まで巻き添えで適用されない**——しかも base が進まない
                // ので案内が永久に消えない［code-review の指摘］。
                let index = spec.index
                guard let target = claimed.contains(index)
                        ? nextFreeIndex(after: claimed) : index
                else { continue }
                claimed.insert(target)
                items.append(TemplateDiff.Item(
                    category: .field, change: .added,
                    action: .addField(index: target, name: spec.name,
                                      assignsAutomatically: spec.assignsAutomatically,
                                      bindings: bindings),
                    subject: spec.name, isLocallyEdited: false))
                continue
            }

            // 既にあるフィールド。**ライブラリ側にその番号が無ければ触らない**
            // ——利用者が消した（または番号を振り直した）ものを復活させない。
            guard let currentField = currentByIndex[spec.index] else { continue }

            if baseSpec.name != spec.name, currentField.name != spec.name {
                items.append(TemplateDiff.Item(
                    category: .field, change: .modified,
                    action: .renameField(index: spec.index, name: spec.name),
                    subject: spec.name, previous: currentField.name,
                    isLocallyEdited: currentField.name != baseSpec.name))
            }
            if baseSpec.assignsAutomatically != spec.assignsAutomatically,
               currentField.assignsAutomatically != spec.assignsAutomatically {
                items.append(TemplateDiff.Item(
                    category: .field, change: .modified,
                    action: .setFieldAutoAssign(index: spec.index,
                                                value: spec.assignsAutomatically),
                    subject: currentField.name,
                    isLocallyEdited: currentField.assignsAutomatically
                        != baseSpec.assignsAutomatically))
            }
        }
        return items
    }

    /// 空いているフィールド番号。**埋まっていれば `nil`**
    /// （`LibrarySettingsDraft.nextAvailableFieldIndex` と同じ規則）。
    private static func nextFreeIndex(after used: Set<Int>) -> Int? {
        (1...AppLimits.Format.maxFields).first { !used.contains($0) }
    }

    // MARK: - ファイル名フォーマット

    private static func filenameFormatItems(base: LibrarySettingsDraft,
                                            latest: LibrarySettingsDraft,
                                            current: LibrarySettingsDraft) -> [TemplateDiff.Item]
    {
        let baseSources = base.filenameFormats.map(\.source)
        let newSources = latest.filenameFormats.map(\.source)
        let currentSources = current.filenameFormats.map(\.source)
        let baseSet = Set(baseSources), newSet = Set(newSources), currentSet = Set(currentSources)

        var items: [TemplateDiff.Item] = []
        for (position, source) in newSources.enumerated()
        where !baseSet.contains(source) && !currentSet.contains(source) {
            items.append(TemplateDiff.Item(
                category: .filenameFormat, change: .added,
                action: .addFilenameFormat(source: source,
                                           after: position > 0 ? newSources[position - 1] : nil),
                subject: source, isLocallyEdited: false))
        }
        for source in baseSources where !newSet.contains(source) && currentSet.contains(source) {
            items.append(TemplateDiff.Item(
                category: .filenameFormat, change: .removed,
                action: .removeFilenameFormat(source: source),
                subject: source, isLocallyEdited: false))
        }

        // **並び順は優先順** [FF-03] なので、内容が同じでも並びが違えば
        // どのファイル名がどのフォーマットに当たるかが実際に変わる。
        // 比べるのは 3 者すべてに在るものだけ——片方にしか無いものを
        // 混ぜると、追加・削除がそのまま「並べ替え」としても出て二重になる。
        let shared = newSources.filter { baseSet.contains($0) && currentSet.contains($0) }
        let currentShared = currentSources.filter { Set(shared).contains($0) }
        let baseShared = baseSources.filter { Set(shared).contains($0) }
        // **プリセットが実際に順序を変えたときだけ出す。** この `baseShared
        // != shared` が無いと、利用者が自分で並べ替えただけで「プリセットの
        // 変更」として提示され、チェックすると自分で決めた優先順が巻き戻る
        // ［code-review の指摘。フィールド名と階層割り当ては同じガードを
        // 持っていたので、ここだけ抜けていた］。
        if shared.count > 1, baseShared != shared, currentShared != shared {
            items.append(TemplateDiff.Item(
                category: .filenameFormatOrder, change: .reordered,
                action: .reorderFilenameFormats(order: shared),
                subject: shared.joined(separator: " / "),
                previous: currentShared.joined(separator: " / "),
                isLocallyEdited: currentShared != baseShared))
        }
        return items
    }

    // MARK: - 巻数フォーマット

    /// **並べ替えは出さない。** 巻数の照合は「最長一致。同長なら登録順」
    /// [05章 §5.4 の実測] なので、並びの意味がファイル名フォーマットとは違い、
    /// 順序だけを入れ替えても結果はほとんど動かない。
    private static func volumeFormatItems(base: LibrarySettingsDraft,
                                          latest: LibrarySettingsDraft,
                                          current: LibrarySettingsDraft) -> [TemplateDiff.Item]
    {
        struct Key: Hashable { let source: String; let kind: VolumePatternKind }
        let baseSet = Set(base.volumeFormats.map { Key(source: $0.source, kind: $0.kind) })
        let newList = latest.volumeFormats.map { Key(source: $0.source, kind: $0.kind) }
        let newSet = Set(newList)
        let currentSet = Set(current.volumeFormats.map { Key(source: $0.source, kind: $0.kind) })

        var items: [TemplateDiff.Item] = []
        for key in newList where !baseSet.contains(key) && !currentSet.contains(key) {
            items.append(TemplateDiff.Item(
                category: .volumeFormat, change: .added,
                action: .addVolumeFormat(source: key.source, kind: key.kind),
                subject: key.source, isLocallyEdited: false))
        }
        for key in base.volumeFormats.map({ Key(source: $0.source, kind: $0.kind) })
        where !newSet.contains(key) && currentSet.contains(key) {
            items.append(TemplateDiff.Item(
                category: .volumeFormat, change: .removed,
                action: .removeVolumeFormat(source: key.source, kind: key.kind),
                subject: key.source, isLocallyEdited: false))
        }
        return items
    }

    // MARK: - フォルダ階層割り当て

    private static func folderLevelItems(base: LibrarySettingsDraft,
                                         latest: LibrarySettingsDraft,
                                         current: LibrarySettingsDraft) -> [TemplateDiff.Item]
    {
        let baseByLevel = Dictionary(base.folderLevels.map { ($0.level, $0.assignment) },
                                     uniquingKeysWith: { a, _ in a })
        let newByLevel = Dictionary(latest.folderLevels.map { ($0.level, $0.assignment) },
                                    uniquingKeysWith: { a, _ in a })
        let currentByLevel = Dictionary(current.folderLevels.map { ($0.level, $0.assignment) },
                                        uniquingKeysWith: { a, _ in a })

        var items: [TemplateDiff.Item] = []
        for level in Set(baseByLevel.keys).union(newByLevel.keys).sorted() {
            let baseValue = baseByLevel[level]
            let newValue = newByLevel[level]
            let currentValue = currentByLevel[level]
            guard baseValue != newValue else { continue }   // プリセットは変えていない
            guard currentValue != newValue else { continue } // 既に同じ

            let edited = currentValue != baseValue
            if let newValue {
                items.append(TemplateDiff.Item(
                    category: .folderLevel,
                    change: currentValue == nil ? .added : .modified,
                    action: .setFolderLevel(level: level, assignment: newValue),
                    subject: describe(level: level, assignment: newValue),
                    previous: currentValue.map { describe(level: level, assignment: $0) },
                    isLocallyEdited: edited))
            } else if currentValue != nil {
                items.append(TemplateDiff.Item(
                    category: .folderLevel, change: .removed,
                    action: .setFolderLevel(level: level, assignment: nil),
                    subject: describe(level: level, assignment: currentValue!),
                    isLocallyEdited: edited))
            }
        }
        return items
    }

    /// 表示用の 1 行。**訳語は View 側で付ける**——ここは `QooKit` なので
    /// 表示言語を知らない [A-01]。値そのものだけを返す。
    private static func describe(level: Int,
                                 assignment: FolderLevelDraft.Assignment) -> String {
        switch assignment {
        case .none:                        return "—"
        case .singleLabelGroup(let index): return "#\(index)"
        case .format(let source):          return source
        }
    }
}
