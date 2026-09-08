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

/// ラベルフィールド 1 件 [LG-01〜LG-07]。
///
/// `index` が `@labelgroupN` の N。**DB の行 ID ではなく `index` が
/// フォーマットから参照される**ので、付け替えるとフォーマットの意味が変わる。
public struct FieldDraft: Sendable, Hashable, Identifiable {
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

/// 巻数フォーマット 1 件 [SE-05][SE-21]。`source` は正規表現。
public struct VolumeFormatDraft: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// 正規表現。巻数は `(?<volume>…)` か唯一のキャプチャグループから取る。
    public var source: String
    public var isEnabled: Bool
    /// 巻数を取り出すのか、シリーズ名を切るだけなのか [VolumePatternKind]。
    public var kind: VolumePatternKind
    /// どの予約語のためのパターンか [MF-07]。設定画面はこれで区画を分ける。
    public var role: PatternRole

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                kind: VolumePatternKind = .volume, role: PatternRole = .volume) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.kind = kind
        self.role = role
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
    public var thumbnailsAlwaysHidden: Bool    // [DS-04]
    /// 重複ファイルをまとめて表示するか [DU-01][DU-02]。**既定は `.off`。**
    ///
    /// **モードの切り替えそのものに再スキャンは要らない**——鍵
    /// （`managedFile.titleKey`）はモードに関わらず常に書いてあり、ここで
    /// 選ぶのは「問い合わせのときに巻数まで見るかどうか」だけ。
    ///
    /// **ただし v6 より前からある行は `titleKey` が NULL** で、走査が埋め直す
    /// まで組に加わらない。**既存のライブラリで初めて有効にしたときは、
    /// 一度再スキャンするまで何も畳まれない。**
    public var duplicateGrouping: DuplicateGrouping  // [DU-01][DU-02]

    // --- 対象 ---
    public var targetExtensions: [String]      // [AL-11][IF-01]
    public var imageExtensions: [String]       // [IF-02]

    // --- 字句 ---
    public var delimiters: DelimiterSet        // [DL-01〜DL-15]
    public var protectedTokens: [ProtectedToken]  // [PT-01〜PT-10]

    // --- ラベル ---
    public var fields: [FieldDraft]
    /// 予約語 → ラベルフィールド番号 [RW-13]。1 対 1 でなければならない [RW-14]。
    public var semanticBindings: [SemanticKeyword: Int]

    // --- フォーマット ---
    public var filenameFormats: [FilenameFormatDraft]
    public var volumeFormats: [VolumeFormatDraft]
    public var folderLevels: [FolderLevelDraft]
    public var seriesTitleCompositionFormat: String   // [SE-33]

    // --- 埋め込みメタデータ [EM-06][EM-30] ---
    /// ファイル自身が持つメタデータ（`ComicInfo.xml` / EPUB / PDF）を読むか。
    public var readsEmbeddedMetadata: Bool
    /// `ComicInfo.xml` の巻数をどちらの要素から取るか。
    public var comicInfoVolumeSource: ComicInfoVolumeSource

    // --- ブックフォルダ [IF-17][IF-18] ---
    /// ブックフォルダの「開く」を関連付けアプリに任せるか [IF-18][AS-06]。
    /// 偽なら既定どおりフォルダを開く（配下の画像一覧を表示する）。
    public var opensBookFolderWithApp: Bool

    // --- 照合の文脈（編集不可） ---
    /// `@mediatype` の照合語彙 [TY-01]。**ライブラリ固有の 1 値ではない**
    /// ——プリセットが持つ本の種別の和集合と、このライブラリの「本の種別」
    /// フィールドに既にあるラベルを合わせたもの。供給するのは永続化層で、
    /// ここは受け取るだけ（草案を編集しても語彙は動かない）。
    public let mediaTypeVocabulary: [String]

    public init(displayName: String = "",
                thumbnailsAlwaysHidden: Bool = false,
                duplicateGrouping: DuplicateGrouping = .off,
                targetExtensions: [String] = [],
                imageExtensions: [String] = [],
                delimiters: DelimiterSet = .default,
                protectedTokens: [ProtectedToken] = [],
                fields: [FieldDraft] = [],
                semanticBindings: [SemanticKeyword: Int] = [:],
                filenameFormats: [FilenameFormatDraft] = [],
                volumeFormats: [VolumeFormatDraft] = [],
                folderLevels: [FolderLevelDraft] = [],
                seriesTitleCompositionFormat: String = "@series @volume",
                readsEmbeddedMetadata: Bool = true,
                comicInfoVolumeSource: ComicInfoVolumeSource = .ask,
                opensBookFolderWithApp: Bool = false,
                mediaTypeVocabulary: [String] = []) {
        self.displayName = displayName
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.duplicateGrouping = duplicateGrouping
        self.targetExtensions = targetExtensions
        self.imageExtensions = imageExtensions
        self.delimiters = delimiters
        self.protectedTokens = protectedTokens
        self.fields = fields
        self.semanticBindings = semanticBindings
        self.filenameFormats = filenameFormats
        self.volumeFormats = volumeFormats
        self.folderLevels = folderLevels
        self.seriesTitleCompositionFormat = seriesTitleCompositionFormat
        self.readsEmbeddedMetadata = readsEmbeddedMetadata
        self.comicInfoVolumeSource = comicInfoVolumeSource
        self.opensBookFolderWithApp = opensBookFolderWithApp
        self.mediaTypeVocabulary = mediaTypeVocabulary
    }

    // MARK: - 派生

    /// フォーマットのコンパイルに渡す文脈。**検証もプレビューもこれを使う**
    /// ——別々に組み立てると、片方だけ設定変更に追随しない形になる。
    public var compilationContext: FormatCompilationContext {
        FormatCompilationContext(delimiters: delimiters,
                                 maxFields: AppLimits.Format.maxFields,
                                 mediaTypeVocabulary: mediaTypeVocabulary,
                                 semanticBindings: semanticBindings)
    }

    public var definedFieldIndexes: Set<Int> { Set(fields.map(\.index)) }

    public func fieldName(at index: Int) -> String? {
        fields.first { $0.index == index }?.name
    }

    /// 次に使える空きフィールド番号。埋まっていれば `nil`。
    public var nextAvailableFieldIndex: Int? {
        let used = definedFieldIndexes
        return (1...AppLimits.Format.maxFields).first { !used.contains($0) }
    }

    // MARK: - 参照名の束縛 [MF-22]

    /// このフィールドが既定フィールド 6 種のどれかか [§19.2]。
    ///
    /// **番号ではなく束縛で判定する**——番号はフィールドの身元ではないので、
    /// 並べ替えると別の行を守ってしまう。
    public func isDefaultField(at index: Int) -> Bool {
        SemanticKeyword.defaultFields.contains { semanticBindings[$0] == index }
    }

    /// そのフィールドへ束縛できる予約語 [MF-22]。**画面のポップアップの中身**。
    ///
    /// ## なぜ既定 6 種を候補に出さないか [§19.7][§19.8]
    /// あの 6 種は**意味そのものが身元**で、付け替えられると「著者フィールドへ
    /// `@genre` が流れる」ような、後から辿れない設定が作れてしまう。ステージ 5 で
    /// 予約語割り当てポップアップを撤去したのはそのため——ここで戻すのは
    /// **既定 6 種以外の軸だけ**である。
    ///
    /// ## 何が並ぶか
    /// - まだどのフィールドにも束縛されていない軸
    /// - **このフィールド自身が今束縛している軸**（外さない限り選択のまま残る）
    ///
    /// 他のフィールドが使っている軸は出さない——1 予約語 → 複数フィールドは
    /// 検証が拒む [RW-14] ので、選べる形にしても保存できない選択肢が並ぶだけ。
    ///
    /// 並びは固定（`@series` → `@season` → `@actor` → `@keyword2`〜`@keyword5`）。
    /// 辞書の列挙順に任せると、開くたびに順序が変わる。
    public func bindableKeywords(forFieldAt index: Int) -> [SemanticKeyword] {
        Self.assignableKeywords.filter { keyword in
            switch semanticBindings[keyword] {
            case .none:        return true
            case .some(index): return true
            default:           return false
            }
        }
    }

    /// このフィールドに今ついている参照名。既定フィールドのものも返す。
    public func boundKeyword(forFieldAt index: Int) -> SemanticKeyword? {
        SemanticKeyword.allCases.first { semanticBindings[$0] == index }
    }

    /// 参照名を付け替える [MF-22]。`nil` で外す。
    ///
    /// **既定フィールドには何もしない**——ボタン側の出し分けと二重の守り
    /// （ステージ 5 が消した「既定フィールドを付け替えられてしまう」問題を
    /// 再現させない）。
    public mutating func bindKeyword(_ keyword: SemanticKeyword?, toFieldAt index: Int) {
        guard !isDefaultField(at: index) else { return }
        for existing in Self.assignableKeywords where semanticBindings[existing] == index {
            semanticBindings[existing] = nil
        }
        if let keyword, Self.assignableKeywords.contains(keyword) {
            semanticBindings[keyword] = index
        }
    }

    /// 画面から付け替えてよい軸（＝既定 6 種以外の意味予約語）。並び順が
    /// そのままポップアップの並びになる。
    public static let assignableKeywords: [SemanticKeyword] = [
        .series, .season, .actor, .keyword2, .keyword3, .keyword4, .keyword5,
    ]
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
        case fields, filenameFormats, volumeFormats, folderLevels
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
    /// 実在しないラベルフィールドへ紐づけようとしたりする。`settingsSnapshot`
    /// が壊れたフォーマットを黙って落とす造りなのは「保存時に検証済み」を
    /// 前提にしているので、その前提をここで満たす。
    /// 何として検証するか [LS-01][LT-02]。
    ///
    /// **表示名の要否だけが違う。** ライブラリの表示名はフォルダ名に追随する
    /// [RG3-31] ので、テンプレート（＝まだどのフォルダにも結び付いていない
    /// 設定の雛形）は持ちようがない。同じ草案の型を使う以上、どちらとして
    /// 見るかを呼び出し側が言う必要がある。
    public enum ValidationContext: Sendable {
        /// ライブラリの設定として。表示名を要求する。
        case library
        /// テンプレートとして [LT-02]。**表示名を要求しない。**
        case template
    }

    public func validate(as context: ValidationContext = .library) -> [LibrarySettingsIssue] {
        var issues: [LibrarySettingsIssue] = []
        func addError(_ section: LibrarySettingsIssue.Section, _ message: String) {
            issues.append(.init(severity: .error, section: section, message: message))
        }
        func addWarning(_ section: LibrarySettingsIssue.Section, _ message: String) {
            issues.append(.init(severity: .warning, section: section, message: message))
        }

        // --- 基本 ---
        if context == .library, displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            addError(.basics, QooKitStrings.text("draft.displayNameRequired"))
        }

        // --- 対象拡張子 ---
        //
        // **空を許してはならない** [AL-11][IF-01]。`LibraryEnumerator` は空を
        // 「絞り込まない＝すべてのファイルが対象」と読むため、`.DS_Store` や
        // メモの `.txt` まで蔵書として取り込む。実際にこの穴を踏んでいる。
        if targetExtensions.isEmpty {
            addError(.extensions, QooKitStrings.text("draft.extensionsEmpty"))
        }
        let overlap = Set(targetExtensions).intersection(Set(imageExtensions))
        if !overlap.isEmpty {
            addWarning(.extensions, QooKitStrings.format("draft.extensionOverlap",
                                         overlap.sorted().joined(separator: ", ")))
        }

        // --- ラベルフィールド ---
        var seenIndexes: Set<Int> = []
        for field in fields {
            if field.index < 1 || field.index > AppLimits.Format.maxFields {
                addError(.fields, QooKitStrings.format("draft.fieldIndexOutOfRange",
                                                       field.index, AppLimits.Format.maxFields))
            }
            if !seenIndexes.insert(field.index).inserted {
                addError(.fields, QooKitStrings.format("draft.fieldIndexDuplicated", field.index))
            }
            if field.name.trimmingCharacters(in: .whitespaces).isEmpty {
                addError(.fields, QooKitStrings.format("draft.fieldNameEmpty", field.index))
            }
        }

        // --- セマンティック予約語 [RW-13][RW-14][LE-02] ---
        //
        // 1 予約語 → 複数フィールド、1 フィールド → 複数予約語のどちらも禁止。
        // 前者は辞書の形が防いでいるので、ここで見るのは後者。
        var groupToKeywords: [Int: [SemanticKeyword]] = [:]
        for (keyword, index) in semanticBindings {
            groupToKeywords[index, default: []].append(keyword)
            if !definedFieldIndexes.contains(index) {
                addError(.fields, QooKitStrings.format("draft.keywordBoundToMissingField",
                                                       keyword.rawValue, index))
            }
        }
        for (index, keywords) in groupToKeywords where keywords.count > 1 {
            addError(.fields, QooKitStrings.format("draft.fieldHasMultipleKeywords", index,
                                                   keywords.map(\.rawValue).sorted().joined(separator: ", ")))
        }

        // --- ファイル名フォーマット ---
        let context = compilationContext
        let defined = definedFieldIndexes
        if filenameFormats.allSatisfy({ !$0.isEnabled }) {
            addWarning(.filenameFormats, QooKitStrings.text("draft.noEnabledFilenameFormat"))
        }
        for (i, format) in filenameFormats.enumerated() {
            // **無効なものも検証する**——後で有効に戻したときに初めて壊れて
            // いると分かるのでは遅い。ただし警告に留め、保存は妨げない。
            let severityIsError = format.isEnabled
            if format.source.trimmingCharacters(in: .whitespaces).isEmpty {
                if severityIsError {
                    addError(.filenameFormats, QooKitStrings.format("draft.filenameFormatEmpty", i + 1))
                }
                continue
            }
            do {
                _ = try FormatCompiler.compile(format.source, context: context, priority: i)
            } catch {
                let message = QooKitStrings.format("draft.filenameFormatInvalid",
                                                   i + 1, format.source, error.whatHappened)
                if severityIsError { addError(.filenameFormats, message) }
                else { addWarning(.filenameFormats, message) }
                continue
            }
            // 束縛の無い意味予約語も同じ壊れ方をする [RW-16][RWI-02]——`@studio`
            // 等は構造化列を持たないので、束縛が無いと切り出した値が捨てられる。
            // **`@labelgroupN` と揃えて弾く**: 片方だけ通すと、フィールドを消した
            // 拍子に「照合は成功するのにラベルが付かない」設定が保存できてしまう。
            for keyword in unboundSemanticKeywords(in: format.source,
                                                   keepsStructuredColumns: true) {
                let message = QooKitStrings.format("draft.unboundKeywordInFilenameFormat",
                                                   i + 1, keyword.rawValue)
                if severityIsError { addError(.filenameFormats, message) }
                else { addWarning(.filenameFormats, message) }
            }
            // **パターンを 1 件も持たない役割を参照しても、保存はできてしまう**
            // [MF-07]——そのフォーマットは永久に一致しないのに、画面には
            // 「未整理が多い」としか出ない。**`@volume` は除く**——素の数字を
            // 型条件に含む [SE-24] ので、パターンが無くても `作品名 01` を拾う。
            for role in patternRolesWithoutPatterns(in: format.source) {
                let message = QooKitStrings.format("draft.formatUsesRoleWithoutPatterns",
                                                   i + 1, role.displayName)
                addWarning(.filenameFormats, message)
            }
        }

        // --- フォルダ階層割り当て [AL-01〜AL-03] ---
        var seenLevels: Set<Int> = []
        for level in folderLevels {
            if level.level < 1 {
                addError(.folderLevels, QooKitStrings.text("draft.folderLevelTooSmall"))
            }
            if !seenLevels.insert(level.level).inserted {
                addError(.folderLevels, QooKitStrings.format("draft.folderLevelDuplicated", level.level))
            }
            switch level.assignment {
            case .none:
                break
            case .singleLabelGroup(let index):
                if !defined.contains(index) {
                    addError(.folderLevels, QooKitStrings.format("draft.folderLevelMissingField",
                                                                 level.level, index))
                }
            case .format(let source):
                if source.trimmingCharacters(in: .whitespaces).isEmpty {
                    addError(.folderLevels, QooKitStrings.format("draft.folderLevelFormatEmpty", level.level))
                    continue
                }
                do {
                    _ = try FormatCompiler.compile(source, context: context)
                } catch {
                    addError(.folderLevels, QooKitStrings.format("draft.folderLevelFormatInvalid",
                                                                 level.level, source, error.whatHappened))
                    continue
                }
                for keyword in unboundSemanticKeywords(in: source,
                                                       keepsStructuredColumns: false) {
                    addError(.folderLevels,
                             QooKitStrings.format("draft.unboundKeywordInFolderLevel",
                                                  level.level, keyword.rawValue))
                }
            }
        }

        // --- 巻数フォーマット [SE-05][SE-21] ---
        //
        // 記法は正規表現。読めないものはエラー、遅くなりうるものは警告にする。
        // **拒否ではなく警告で足りる**のは、実行時に `SafeRegex` のウォッチドッグが
        // 必ず時間の上限で打ち切るため [三層防御の ①]。
        // **番号は役割ごとに数える。** 4 つの役割が 1 つの表に同居する [MF-07]
        // ので、通し番号で「3 番目」と言われても設定画面のどの区画の 3 番目か
        // 分からない——画面は役割ごとに区画を分けて並べる。
        var indexByRole: [PatternRole: Int] = [:]
        for pattern in volumeFormats {
            let ordinal = (indexByRole[pattern.role] ?? 0) + 1
            indexByRole[pattern.role] = ordinal
            let role = pattern.role.displayName

            if pattern.source.trimmingCharacters(in: .whitespaces).isEmpty {
                let message = QooKitStrings.format("draft.volumeFormatEmpty", ordinal, role)
                if pattern.isEnabled { addError(.volumeFormats, message) } else { addWarning(.volumeFormats, message) }
                continue
            }
            guard pattern.isEnabled else { continue }

            for finding in RegexSafety.staticFindings(pattern.source) {
                let message = QooKitStrings.format("draft.volumeFormatFinding", ordinal, role, finding.message)
                if finding.isError { addError(.volumeFormats, message) }
                else { addWarning(.volumeFormats, message) }
            }

            // 値をどこから取るかが一意に決まらないと読めない。
            guard pattern.kind == .volume, let regex = try? SafeRegex(pattern.source) else { continue }
            // 公開日は `year` が必須で、`month`／`day` が増えても曖昧にならない
            // ——`DateMatcher` が名前で読むため [MF-19]。
            if pattern.role == .date {
                if !regex.namedGroups.contains("year") {
                    addError(.volumeFormats,
                             QooKitStrings.format("draft.dateFormatNoYearGroup", ordinal, role))
                }
                continue
            }
            let name = pattern.role.disambiguatingGroupName
            if regex.captureGroupCount == 0 {
                addError(.volumeFormats,
                         QooKitStrings.format("draft.volumeFormatNoCaptureGroup", ordinal, role))
            } else if regex.captureGroupCount > 1, !regex.namedGroups.contains(name) {
                addError(.volumeFormats,
                         QooKitStrings.format("draft.volumeFormatAmbiguousCaptureGroup",
                                              ordinal, role, regex.captureGroupCount, name))
            }
        }

        // --- 保護文字列 [PT-01] ---
        for (i, token) in protectedTokens.enumerated() {
            if token.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                addError(.protectedTokens, QooKitStrings.text("draft.protectedTokenEmpty"))
                continue
            }
            guard token.isEnabled else { continue }
            for finding in RegexSafety.staticFindings(token.pattern) {
                let message = QooKitStrings.format("draft.protectedTokenFinding", i + 1, finding.message)
                if finding.isError { addError(.protectedTokens, message) }
                else { addWarning(.protectedTokens, message) }
            }
        }

        return issues
    }

    /// そのフォーマットが参照する型付き予約語のうち、**有効なパターンを
    /// 1 件も持たない役割**を返す [MF-07]。
    ///
    /// `@volume` は含めない——素の数字を型条件に含む [SE-24] ので、パターンが
    /// 無くても働く。`@season` / `@episode` / `@date` は登録済みのパターンに
    /// しか当たらない [MF-21] ので、無ければ**その予約語は決して一致しない。**
    func patternRolesWithoutPatterns(in source: String) -> [PatternRole] {
        guard let tokens = try? FormatLexer.lex(source, delimiters: delimiters) else { return [] }
        var used: Set<PatternRole> = []
        for case .reservedWord(let ref, _) in tokens {
            switch ref {
            case .season:  used.insert(.season)
            case .episode: used.insert(.episode)
            case .date:    used.insert(.date)
            default:       break
            }
        }
        let available = Set(volumeFormats.filter(\.isEnabled).map(\.role))
        return PatternRole.allCases.filter { used.contains($0) && !available.contains($0) }
    }

    /// 実際に正規表現を走らせて時間を測る検査 [三層防御の ③]。
    ///
    /// **`validate()` とは別にしてある。** あちらは描画のたびに何度も呼ばれるので、
    /// 実測を混ぜると危険な正規表現を直している最中に画面が重くなる。こちらは
    /// 保存のような明示的な区切りでだけ呼ぶこと。
    ///
    /// 見つかるのは警告だけ——実行時は `SafeRegex` のウォッチドッグが必ず打ち切る
    /// ので、保存を妨げる理由が無い [三層防御の ①]。
    ///
    /// - Parameter samples: そのライブラリの実ファイル名。敵対的な合成標本に加える。
    public func measuredIssues(samples: [String] = []) -> [LibrarySettingsIssue] {
        var issues: [LibrarySettingsIssue] = []
        // 番号は `validate()` と同じく**役割ごとに数える** [MF-07]——2 つの
        // 一覧で同じパターンが違う番号で呼ばれると、どれの話か分からなくなる。
        var indexByRole: [PatternRole: Int] = [:]
        for pattern in volumeFormats {
            let ordinal = (indexByRole[pattern.role] ?? 0) + 1
            indexByRole[pattern.role] = ordinal
            guard pattern.isEnabled else { continue }
            for finding in RegexSafety.measuredFindings(pattern.source, samples: samples) {
                issues.append(.init(severity: .warning, section: .volumeFormats,
                                    message: QooKitStrings.format("draft.volumeFormatFinding",
                                                                  ordinal, pattern.role.displayName,
                                                                  finding.message)))
            }
        }
        for (i, token) in protectedTokens.enumerated() where token.isEnabled {
            for finding in RegexSafety.measuredFindings(token.pattern, samples: samples) {
                issues.append(.init(severity: .warning, section: .protectedTokens,
                                    message: QooKitStrings.format("draft.protectedTokenFinding",
                                                                  i + 1, finding.message)))
            }
        }
        return issues
    }

    public var validationErrors: [LibrarySettingsIssue] {
        validate().filter { $0.severity == .error }
    }

    /// フォーマットが参照している意味予約語のうち、**束縛が無く、その用途では
    /// 値が残らない**もの [RW-16][RWI-02]。
    ///
    /// **コンパイル結果からではなくソースから拾う。** コンパイル済みの構文木は
    /// 検証を通ったものしか作れないので、壊れているフォーマットについて
    /// 何も言えなくなる。
    ///
    /// **ファイル名とフォルダ名で「値が残るか」が違う。**
    /// ファイル名では `@series` / `@author` が構造化列（`seriesName` /
    /// `authorName`）へ入るので、束縛が無くても書く意味がある——照合だけの
    /// 用途にも使える。**フォルダ名フォーマットでは入らない**
    /// （`FolderLabelResolver` が返すのはラベルだけで、タイトル・シリーズ・
    /// 著者はファイル名側から決まる [AL-22]）ので、束縛が無ければ捨てられる。
    func unboundSemanticKeywords(in source: String,
                                 keepsStructuredColumns: Bool) -> [SemanticKeyword] {
        SemanticKeyword.allCases.filter { keyword in
            // **`@mediatype` は束縛が無くても不備ではない** [TY-01、2026-09-04]。
            // 他の意味予約語と違い、**照合そのものに意味がある**（語彙に無い語で
            // 始まるファイル名を後続のフォーマットへ落とす型条件）——束縛すれば
            // 本の種別ラベルにもなる、というのが上乗せの利点にすぎない。
            // ここを外すと、`(@mediatype)` を持つ既存ライブラリが「未束縛の予約語」
            // として設定を一切保存できなくなる。
            if keyword == .mediaType { return false }
            if keepsStructuredColumns, keyword.hasStructuredColumn { return false }
            guard semanticBindings[keyword] == nil else { return false }
            return Self.references(keyword, in: source)
        }
    }

    /// `source` がその予約語を**綴りとして**含むか。
    ///
    /// **素の `contains` では駄目** [MF-22、2026-09-08]——`@keyword2` は
    /// `@keyword` を部分文字列として含むので、カスタム軸を書いただけで
    /// 「`@keyword` が束縛されていません」という**存在しない不備**が出て
    /// 保存できなくなる（実際に踏んだ）。字句解析は最長一致で読む [LX-01] ので、
    /// ここも綴りの直後が英数字なら別の予約語とみなす。
    static func references(_ keyword: SemanticKeyword, in source: String) -> Bool {
        let word = keyword.rawValue
        var searchRange = source.startIndex..<source.endIndex
        while let found = source.range(of: word, range: searchRange) {
            if found.upperBound == source.endIndex
                || !source[found.upperBound].isLetterOrDigit {
                return true
            }
            searchRange = found.upperBound..<source.endIndex
        }
        return false
    }
}

private extension Character {
    /// ASCII の英数字。予約語の綴りは `@` ＋ 英小文字＋数字なので、境界の
    /// 判定はこれで足りる。
    var isLetterOrDigit: Bool { isLetter || isNumber }
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
                                 priority: priority, kind: pattern.kind)
        }

        return LibrarySettingsSnapshot(
            libraryID: libraryID,
            settingsRevision: settingsRevision,
            displayName: displayName,
            mediaTypeVocabulary: mediaTypeVocabulary,
            targetExtensions: Set(targetExtensions),
            imageExtensions: Set(imageExtensions),
            delimiters: delimiters,
            protectedTokens: ProtectedTokenCompiler.compileAll(protectedTokens),
            filenameFormats: formats,
            folderLevelAssignments: levels,
            volumeFormats: VolumePatternCompiler.compileAll(patterns),
            semanticBindings: semanticBindings,
            seriesTitleCompositionFormat: seriesTitleCompositionFormat)
    }
}
