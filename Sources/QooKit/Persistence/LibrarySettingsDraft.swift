//
//  ライブラリ設定の編集草案 [LS-01〜LS-03][LT-03]。
//
//  **`LibrarySettingsSnapshot`（パーサ用）とは別物である。** スナップショットは
//  コンパイル済みで、しかも無効なフォーマットを落として返す——編集にそれを使うと
//  ①ソース文字列が失われて直せない ②無効にしていたフォーマットが保存で消える。
//  編集経路は必ずこちらを通すこと。
//
//  テンプレートは登録時に一度写されるだけの雛形で [LT-03]、以後の設定はこの草案を
//  通じてライブラリ側で自由に変えられる。テンプレート本体には影響しない。
//
import Foundation

// MARK: - 部品

/// ラベルグループ 1 件 [LG-01〜LG-07]。
///
/// `index` が `@labelgroupN` の N。**DB の行 ID ではなく `index` が
/// フォーマットから参照される**ので、付け替えるとフォーマットの意味が変わる。
public struct LabelGroupDraft: Sendable, Hashable, Identifiable {
    /// UI 上の安定した識別子。DB の行 ID とは無関係（新規行はまだ ID を持たない）。
    public let id: UUID
    /// DB の行 ID。既存行の同定に使う。新規なら `nil`。
    public let persistentID: Int64?
    public var index: Int
    public var name: String
    public var colorHexLight: String
    public var colorHexDark: String
    public var assignsAutomatically: Bool      // [AL-04]

    public init(id: UUID = UUID(), persistentID: Int64? = nil, index: Int, name: String,
                colorHexLight: String, colorHexDark: String,
                assignsAutomatically: Bool = true) {
        self.id = id
        self.persistentID = persistentID
        self.index = index
        self.name = name
        self.colorHexLight = colorHexLight
        self.colorHexDark = colorHexDark
        self.assignsAutomatically = assignsAutomatically
    }
}

/// ファイル名フォーマット 1 件 [FF-03〜FF-05]。**優先順は配列の並び順**で表す
/// ——`priority` を値として持つと、並べ替えのたびに全件の付け直しが要る。
public struct FilenameFormatDraft: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var source: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
    }
}

/// 巻数フォーマット 1 件 [SE-05][SE-21]。
public struct VolumeFormatDraft: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var source: String
    public var isEnabled: Bool
    /// 序数（上巻・下巻など）の順位 [SE-11]。数値巻ではない場合に使う。
    public var ordinalRank: Int?

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                ordinalRank: Int? = nil) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.ordinalRank = ordinalRank
    }
}

/// フォルダ階層 1 段の割り当て [AL-01〜AL-03]。
public struct FolderLevelDraft: Sendable, Hashable, Identifiable {
    /// 割り当ての種類。**`.none`（明示的に割り当てない）と「行が無い」は別の意味**
    /// [AL-03]——前者は「この階層は使わないと決めた」、後者は「未設定」。
    public enum Assignment: Sendable, Hashable {
        case none
        case singleLabelGroup(index: Int)
        /// フォーマット文字列（**コンパイル前**）。
        case format(source: String)
    }

    public let id: UUID
    /// 1 = ライブラリ直下 [AL-01]。
    public var level: Int
    public var assignment: Assignment

    public init(id: UUID = UUID(), level: Int, assignment: Assignment) {
        self.id = id
        self.level = level
        self.assignment = assignment
    }
}

// MARK: - 草案

public struct LibrarySettingsDraft: Sendable, Equatable {

    // --- 基本 ---
    public var displayName: String
    /// `@librarytype` の照合値 [RW-01]。表示名とは別物で、こちらが型条件 [TY-01]
    /// の判定に使われる（実蔵書との突き合わせで、ここの食い違いが 146 件の
    /// 未解決を生んだ実例がある）。
    public var libraryTypeName: String
    public var caseSensitive: Bool             // [N-04]
    public var thumbnailsAlwaysHidden: Bool    // [DS-04]

    // --- 対象 ---
    public var targetExtensions: [String]      // [AL-11][IF-01]
    public var imageExtensions: [String]       // [IF-02]

    // --- 字句 ---
    public var delimiters: DelimiterSet        // [DL-01〜DL-15]
    public var protectedTokens: [ProtectedToken]  // [PT-01〜PT-10]

    // --- ラベル ---
    public var labelGroups: [LabelGroupDraft]
    /// 予約語 → ラベルグループ番号 [RW-13]。1 対 1 でなければならない [RW-14]。
    public var semanticBindings: [SemanticKeyword: Int]

    // --- フォーマット ---
    public var filenameFormats: [FilenameFormatDraft]
    public var volumeFormats: [VolumeFormatDraft]
    public var folderLevels: [FolderLevelDraft]
    public var seriesTitleCompositionFormat: String   // [SE-33]

    // --- 照合の文脈（編集不可） ---
    /// **この**ライブラリを除いた他ライブラリの型名・表示名。型付き照合 [TY-01]
    /// の列挙候補を組み立てるのに要る。自分の分は編集中の値から足すので、
    /// 型名を書き換えても列挙候補が古いまま取り残されない。
    public let otherLibraryTypeNames: [String]
    public let otherLibraryDisplayNames: [String]

    public init(displayName: String = "",
                libraryTypeName: String = "",
                caseSensitive: Bool = false,
                thumbnailsAlwaysHidden: Bool = false,
                targetExtensions: [String] = [],
                imageExtensions: [String] = [],
                delimiters: DelimiterSet = .default,
                protectedTokens: [ProtectedToken] = [],
                labelGroups: [LabelGroupDraft] = [],
                semanticBindings: [SemanticKeyword: Int] = [:],
                filenameFormats: [FilenameFormatDraft] = [],
                volumeFormats: [VolumeFormatDraft] = [],
                folderLevels: [FolderLevelDraft] = [],
                seriesTitleCompositionFormat: String = "@series @volume",
                otherLibraryTypeNames: [String] = [],
                otherLibraryDisplayNames: [String] = []) {
        self.displayName = displayName
        self.libraryTypeName = libraryTypeName
        self.caseSensitive = caseSensitive
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.targetExtensions = targetExtensions
        self.imageExtensions = imageExtensions
        self.delimiters = delimiters
        self.protectedTokens = protectedTokens
        self.labelGroups = labelGroups
        self.semanticBindings = semanticBindings
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.folderLevels = folderLevels
        self.seriesTitleCompositionFormat = seriesTitleCompositionFormat
        self.otherLibraryTypeNames = otherLibraryTypeNames
        self.otherLibraryDisplayNames = otherLibraryDisplayNames
    }

    // MARK: - 派生

    public var allLibraryTypeNames: [String] {
        Array(Set(otherLibraryTypeNames + [libraryTypeName])).filter { !$0.isEmpty }.sorted()
    }

    public var allLibraryDisplayNames: [String] {
        Array(Set(otherLibraryDisplayNames + [displayName])).filter { !$0.isEmpty }.sorted()
    }

    public var normalization: NormalizationOptions {
        NormalizationOptions(caseSensitive: caseSensitive)
    }

    /// フォーマットのコンパイルに渡す文脈。**検証もプレビューもこれを使う**
    /// ——別々に組み立てると、片方だけ設定変更に追随しない形になる。
    public var compilationContext: FormatCompilationContext {
        FormatCompilationContext(delimiters: delimiters,
                                 maxLabelGroups: AppLimits.Format.maxLabelGroups,
                                 allLibraryTypeNames: allLibraryTypeNames,
                                 allLibraryDisplayNames: allLibraryDisplayNames,
                                 semanticBindings: semanticBindings,
                                 normalization: normalization)
    }

    public var definedLabelGroupIndexes: Set<Int> { Set(labelGroups.map(\.index)) }

    public func labelGroupName(at index: Int) -> String? {
        labelGroups.first { $0.index == index }?.name
    }

    /// 次に使える空きグループ番号。埋まっていれば `nil`。
    public var nextAvailableLabelGroupIndex: Int? {
        let used = definedLabelGroupIndexes
        return (1...AppLimits.Format.maxLabelGroups).first { !used.contains($0) }
    }
}

// MARK: - 検証

/// 設定の不備 1 件。**最初の 1 件で打ち切らず全部返す**——保存できない理由が
/// 1 つずつしか分からないと、直すたびに保存を試す往復になる。
public struct LibrarySettingsIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable {
        /// 保存を拒否する。
        case error
        /// 保存はできるが、そのままでは意図した動作にならない可能性がある。
        case warning
    }

    /// 不備が属する設定項目。UI が「どのページを開けばよいか」を示すのに使う。
    public enum Section: String, Sendable, Hashable {
        case basics, extensions, delimiters, protectedTokens
        case labelGroups, filenameFormats, volumeFormats, folderLevels
    }

    public let id: UUID
    public let severity: Severity
    public let section: Section
    public let message: String

    public init(id: UUID = UUID(), severity: Severity, section: Section, message: String) {
        self.id = id
        self.severity = severity
        self.section = section
        self.message = message
    }
}

extension LibrarySettingsDraft {

    /// 保存前の検証 [LS-01]。**純粋関数**——DB も実ファイルも見ない。
    ///
    /// 壊れた設定を DB へ入れると、次のスキャンで全件が未解決になったり、
    /// 実在しないラベルグループへ紐づけようとしたりする。`settingsSnapshot`
    /// が壊れたフォーマットを黙って落とす造りなのは「保存時に検証済み」を
    /// 前提にしているので、その前提をここで満たす。
    public func validate() -> [LibrarySettingsIssue] {
        var issues: [LibrarySettingsIssue] = []
        func addError(_ section: LibrarySettingsIssue.Section, _ message: String) {
            issues.append(.init(severity: .error, section: section, message: message))
        }
        func addWarning(_ section: LibrarySettingsIssue.Section, _ message: String) {
            issues.append(.init(severity: .warning, section: section, message: message))
        }

        // --- 基本 ---
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            addError(.basics, "表示名を入力してください。")
        }
        if libraryTypeName.trimmingCharacters(in: .whitespaces).isEmpty {
            addError(.basics, "ライブラリタイプ名を入力してください。@librarytype の照合に使われます。")
        }

        // --- 対象拡張子 ---
        //
        // **空を許してはならない** [AL-11][IF-01]。`LibraryEnumerator` は空を
        // 「絞り込まない＝すべてのファイルが対象」と読むため、`.DS_Store` や
        // メモの `.txt` まで蔵書として取り込む。実際にこの穴を踏んでいる。
        if targetExtensions.isEmpty {
            addError(.extensions, "対象拡張子が空です。空にすると、隠しファイルを含むすべてのファイルが蔵書として取り込まれます。")
        }
        let overlap = Set(targetExtensions).intersection(Set(imageExtensions))
        if !overlap.isEmpty {
            addWarning(.extensions, "対象拡張子と画像拡張子が重複しています: \(overlap.sorted().joined(separator: ", "))")
        }

        // --- ラベルグループ ---
        var seenIndexes: Set<Int> = []
        for group in labelGroups {
            if group.index < 1 || group.index > AppLimits.Format.maxLabelGroups {
                addError(.labelGroups,
                      "グループ番号 \(group.index) は 1〜\(AppLimits.Format.maxLabelGroups) の範囲外です。")
            }
            if !seenIndexes.insert(group.index).inserted {
                addError(.labelGroups, "グループ番号 \(group.index) が重複しています。")
            }
            if group.name.trimmingCharacters(in: .whitespaces).isEmpty {
                addError(.labelGroups, "グループ \(group.index) の名前が空です。")
            }
        }

        // --- セマンティック予約語 [RW-13][RW-14][LE-02] ---
        //
        // 1 予約語 → 複数グループ、1 グループ → 複数予約語のどちらも禁止。
        // 前者は辞書の形が防いでいるので、ここで見るのは後者。
        var groupToKeywords: [Int: [SemanticKeyword]] = [:]
        for (keyword, index) in semanticBindings {
            groupToKeywords[index, default: []].append(keyword)
            if !definedLabelGroupIndexes.contains(index) {
                addError(.labelGroups,
                      "\(keyword.rawValue) が存在しないグループ \(index) に紐づいています。")
            }
        }
        for (index, keywords) in groupToKeywords where keywords.count > 1 {
            addError(.labelGroups,
                  "グループ \(index) に複数の予約語が紐づいています: "
                  + keywords.map(\.rawValue).sorted().joined(separator: ", "))
        }

        // --- ファイル名フォーマット ---
        let context = compilationContext
        let defined = definedLabelGroupIndexes
        if filenameFormats.allSatisfy({ !$0.isEnabled }) {
            addWarning(.filenameFormats,
                 "有効なファイル名フォーマットが 1 つもありません。すべてのファイルが未解決になります。")
        }
        for (i, format) in filenameFormats.enumerated() {
            // **無効なものも検証する**——後で有効に戻したときに初めて壊れて
            // いると分かるのでは遅い。ただし警告に留め、保存は妨げない。
            let severityIsError = format.isEnabled
            if format.source.trimmingCharacters(in: .whitespaces).isEmpty {
                if severityIsError { addError(.filenameFormats, "\(i + 1) 番目のフォーマットが空です。") }
                continue
            }
            do {
                _ = try FormatCompiler.compile(format.source, context: context, priority: i)
            } catch {
                let message = "\(i + 1) 番目のフォーマット「\(format.source)」: \(error.whatHappened)"
                if severityIsError { addError(.filenameFormats, message) }
                else { addWarning(.filenameFormats, message) }
                continue
            }
            // コンパイラは番号の上限（1〜10）しか見ない [LG-01]。**このライブラリに
            // そのグループが実在するか**は見ないので、ここで補う——実在しない
            // グループへ付与しようとすると、照合は成功するのにラベルが付かない、
            // という気づきにくい壊れ方をする。
            for index in referencedLabelGroups(in: format.source) where !defined.contains(index) {
                let message = "\(i + 1) 番目のフォーマットが、存在しないグループ @labelgroup\(index) を参照しています。"
                if severityIsError { addError(.filenameFormats, message) }
                else { addWarning(.filenameFormats, message) }
            }
        }

        // --- フォルダ階層割り当て [AL-01〜AL-03] ---
        var seenLevels: Set<Int> = []
        for level in folderLevels {
            if level.level < 1 {
                addError(.folderLevels, "階層番号は 1 以上にしてください（1 = ライブラリ直下）。")
            }
            if !seenLevels.insert(level.level).inserted {
                addError(.folderLevels, "階層 \(level.level) の割り当てが重複しています。")
            }
            switch level.assignment {
            case .none:
                break
            case .singleLabelGroup(let index):
                if !defined.contains(index) {
                    addError(.folderLevels, "階層 \(level.level) が、存在しないグループ \(index) に割り当てられています。")
                }
            case .format(let source):
                if source.trimmingCharacters(in: .whitespaces).isEmpty {
                    addError(.folderLevels, "階層 \(level.level) のフォーマットが空です。")
                    continue
                }
                do {
                    _ = try FormatCompiler.compile(source, context: context)
                } catch {
                    addError(.folderLevels, "階層 \(level.level)「\(source)」: \(error.whatHappened)")
                    continue
                }
                for index in referencedLabelGroups(in: source) where !defined.contains(index) {
                    addError(.folderLevels,
                          "階層 \(level.level) が、存在しないグループ @labelgroup\(index) を参照しています。")
                }
            }
        }

        // --- 巻数フォーマット [SE-05][SE-21] ---
        for (i, pattern) in volumeFormats.enumerated()
        where pattern.source.trimmingCharacters(in: .whitespaces).isEmpty {
            let message = "\(i + 1) 番目の巻数フォーマットが空です。"
            if pattern.isEnabled { addError(.volumeFormats, message) } else { addWarning(.volumeFormats, message) }
        }

        // --- 保護文字列 [PT-01] ---
        for token in protectedTokens
        where token.text.trimmingCharacters(in: .whitespaces).isEmpty {
            addError(.protectedTokens, "空の保護文字列があります。")
        }

        return issues
    }

    public var validationErrors: [LibrarySettingsIssue] {
        validate().filter { $0.severity == .error }
    }

    /// フォーマット文字列が参照しているラベルグループ番号。
    ///
    /// **コンパイル結果からではなくソースから拾う。** コンパイル済みの構文木は
    /// 検証を通ったものしか作れないので、「壊れているうえに存在しないグループを
    /// 参照している」場合に何も言えなくなる。
    func referencedLabelGroups(in source: String) -> Set<Int> {
        var found: Set<Int> = []
        let scalars = Array(source)
        let keyword = Array("@labelgroup")
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "@",
                  i + keyword.count <= scalars.count,
                  Array(scalars[i..<(i + keyword.count)]) == keyword else {
                i += 1
                continue
            }
            var j = i + keyword.count
            var digits = ""
            while j < scalars.count, scalars[j].isNumber {
                digits.append(scalars[j])
                j += 1
            }
            if let value = Int(digits) { found.insert(value) }
            i = max(j, i + 1)
        }
        return found
    }
}

// MARK: - プレビュー

extension LibrarySettingsDraft {

    /// 草案をパーサ用のスナップショットへ組み立てる [FF-06][HP-05]。
    ///
    /// **保存を経由せずにプレビューできる**ようにするための関数。編集中の値を
    /// そのまま試せないと、「保存 → 走査 → 結果を見る → 直す」という重い往復に
    /// なる——設定しきれないことが要件定義書 R-04 の大リスクなので、そこは軽くする。
    ///
    /// **壊れたフォーマットは黙って落とす。** 編集の途中で壊れているのは普通の
    /// 状態で、そこで例外を投げるとプレビューが一切出せなくなる。壊れていることは
    /// ``validate()`` が別途伝える——「試せる」と「保存できる」は別の関門である。
    public func compiledSnapshot(libraryID: LibraryID = LibraryID(rawValue: 0),
                                 settingsRevision: Int = 0) -> LibrarySettingsSnapshot {
        let context = compilationContext
        var formats: [CompiledFormat] = []
        for (priority, format) in filenameFormats.enumerated() where format.isEnabled {
            guard let compiled = try? FormatCompiler.compile(
                format.source, context: context, isEnabled: true, priority: priority) else { continue }
            formats.append(compiled)
        }

        var levels: [Int: FolderLevelMappingSpec.Assignment] = [:]
        for level in folderLevels {
            switch level.assignment {
            case .none:
                levels[level.level] = FolderLevelMappingSpec.Assignment.none
            case .singleLabelGroup(let index):
                levels[level.level] = .singleLabelGroup(index: index)
            case .format(let source):
                guard let compiled = try? FormatCompiler.compile(source, context: context) else { continue }
                levels[level.level] = .format(compiled)
            }
        }

        let patterns = volumeFormats.enumerated().compactMap { priority, pattern -> VolumePattern? in
            guard pattern.isEnabled, !pattern.source.isEmpty else { return nil }
            return VolumePattern(source: pattern.source, isEnabled: true,
                                 priority: priority, ordinalRank: pattern.ordinalRank)
        }

        return LibrarySettingsSnapshot(
            libraryID: libraryID,
            settingsRevision: settingsRevision,
            displayName: displayName,
            libraryTypeName: libraryTypeName,
            allLibraryTypeNames: allLibraryTypeNames,
            allLibraryDisplayNames: allLibraryDisplayNames,
            targetExtensions: Set(targetExtensions),
            imageExtensions: Set(imageExtensions),
            delimiters: delimiters,
            protectedTokens: protectedTokens,
            filenameFormats: formats,
            folderLevelAssignments: levels,
            volumeFormats: VolumePatternCompiler.compileAll(patterns),
            semanticBindings: semanticBindings,
            normalization: normalization,
            seriesTitleCompositionFormat: seriesTitleCompositionFormat)
    }
}
