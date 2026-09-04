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

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                kind: VolumePatternKind = .volume) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.kind = kind
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
    /// `@booktype` の照合語彙 [TY-01]。**ライブラリ固有の 1 値ではない**
    /// ——プリセットが持つ本の種別の和集合と、このライブラリの「本の種別」
    /// フィールドに既にあるラベルを合わせたもの。供給するのは永続化層で、
    /// ここは受け取るだけ（草案を編集しても語彙は動かない）。
    public let bookTypeVocabulary: [String]

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
                bookTypeVocabulary: [String] = []) {
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
        self.bookTypeVocabulary = bookTypeVocabulary
    }

    // MARK: - 派生

    /// フォーマットのコンパイルに渡す文脈。**検証もプレビューもこれを使う**
    /// ——別々に組み立てると、片方だけ設定変更に追随しない形になる。
    public var compilationContext: FormatCompilationContext {
        FormatCompilationContext(delimiters: delimiters,
                                 maxFields: AppLimits.Format.maxFields,
                                 bookTypeVocabulary: bookTypeVocabulary,
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
            addError(.basics, "表示名を入力してください。")
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

        // --- ラベルフィールド ---
        var seenIndexes: Set<Int> = []
        for field in fields {
            if field.index < 1 || field.index > AppLimits.Format.maxFields {
                addError(.fields,
                      "フィールド番号 \(field.index) は 1〜\(AppLimits.Format.maxFields) の範囲外です。")
            }
            if !seenIndexes.insert(field.index).inserted {
                addError(.fields, "フィールド番号 \(field.index) が重複しています。")
            }
            if field.name.trimmingCharacters(in: .whitespaces).isEmpty {
                addError(.fields, "フィールド \(field.index) の名前が空です。")
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
                addError(.fields,
                      "\(keyword.rawValue) が存在しないフィールド \(index) に紐づいています。")
            }
        }
        for (index, keywords) in groupToKeywords where keywords.count > 1 {
            addError(.fields,
                  "フィールド \(index) に複数の予約語が紐づいています: "
                  + keywords.map(\.rawValue).sorted().joined(separator: ", "))
        }

        // --- ファイル名フォーマット ---
        let context = compilationContext
        let defined = definedFieldIndexes
        if filenameFormats.allSatisfy({ !$0.isEnabled }) {
            addWarning(.filenameFormats,
                 "有効なファイル名フォーマットが 1 つもありません。すべてのファイルがどのフォーマットにも一致しなくなり、ラベルが付きません。")
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
            // 束縛の無い意味予約語も同じ壊れ方をする [RW-16][RWI-02]——`@circle`
            // 等は構造化列を持たないので、束縛が無いと切り出した値が捨てられる。
            // **`@labelgroupN` と揃えて弾く**: 片方だけ通すと、フィールドを消した
            // 拍子に「照合は成功するのにラベルが付かない」設定が保存できてしまう。
            for keyword in unboundSemanticKeywords(in: format.source,
                                                   keepsStructuredColumns: true) {
                let message = "\(i + 1) 番目のフォーマットの \(keyword.rawValue) は、"
                    + "どのフィールドにも紐づいていないため値が失われます。"
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
                    addError(.folderLevels, "階層 \(level.level) が、存在しないフィールド \(index) に割り当てられています。")
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
                for keyword in unboundSemanticKeywords(in: source,
                                                       keepsStructuredColumns: false) {
                    addError(.folderLevels,
                          "階層 \(level.level) の \(keyword.rawValue) は、"
                          + "どのフィールドにも紐づいていないため値が失われます。")
                }
            }
        }

        // --- 巻数フォーマット [SE-05][SE-21] ---
        //
        // 記法は正規表現。読めないものはエラー、遅くなりうるものは警告にする。
        // **拒否ではなく警告で足りる**のは、実行時に `SafeRegex` のウォッチドッグが
        // 必ず時間の上限で打ち切るため [三層防御の ①]。
        for (i, pattern) in volumeFormats.enumerated() {
            let label = "\(i + 1) 番目の巻数フォーマット"
            if pattern.source.trimmingCharacters(in: .whitespaces).isEmpty {
                let message = "\(label)が空です。"
                if pattern.isEnabled { addError(.volumeFormats, message) } else { addWarning(.volumeFormats, message) }
                continue
            }
            guard pattern.isEnabled else { continue }

            for finding in RegexSafety.staticFindings(pattern.source) {
                let message = "\(label): \(finding.message)"
                if finding.isError { addError(.volumeFormats, message) }
                else { addWarning(.volumeFormats, message) }
            }

            // 巻数の値をどこから取るかが一意に決まらないと読めない。
            guard pattern.kind == .volume, let regex = try? SafeRegex(pattern.source) else { continue }
            if regex.captureGroupCount == 0 {
                addError(.volumeFormats,
                         "\(label): 巻数を取り出すキャプチャグループがありません。"
                         + "巻数にあたる部分を `(` `)` で囲んでください（例: `第([0-9]+)巻`）。"
                         + "シリーズ名を切るだけなら種別を「区切り」にしてください。")
            } else if regex.captureGroupCount > 1, !regex.hasNamedVolumeGroup {
                addError(.volumeFormats,
                         "\(label): キャプチャグループが \(regex.captureGroupCount) 個あり、"
                         + "どれが巻数か決まりません。巻数以外は `(?:…)` にするか、"
                         + "巻数を `(?<\(volumeCaptureGroupName)>…)` と名前付きにしてください。")
            }
        }

        // --- 保護文字列 [PT-01] ---
        for (i, token) in protectedTokens.enumerated() {
            let label = "\(i + 1) 番目の保護文字列"
            if token.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                addError(.protectedTokens, "空の保護文字列があります。")
                continue
            }
            guard token.isEnabled else { continue }
            for finding in RegexSafety.staticFindings(token.pattern) {
                let message = "\(label): \(finding.message)"
                if finding.isError { addError(.protectedTokens, message) }
                else { addWarning(.protectedTokens, message) }
            }
        }

        return issues
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
        for (i, pattern) in volumeFormats.enumerated() where pattern.isEnabled {
            for finding in RegexSafety.measuredFindings(pattern.source, samples: samples) {
                issues.append(.init(severity: .warning, section: .volumeFormats,
                                    message: "\(i + 1) 番目の巻数フォーマット: \(finding.message)"))
            }
        }
        for (i, token) in protectedTokens.enumerated() where token.isEnabled {
            for finding in RegexSafety.measuredFindings(token.pattern, samples: samples) {
                issues.append(.init(severity: .warning, section: .protectedTokens,
                                    message: "\(i + 1) 番目の保護文字列: \(finding.message)"))
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
            // **`@booktype` は束縛が無くても不備ではない** [TY-01、2026-09-04]。
            // 他の意味予約語と違い、**照合そのものに意味がある**（語彙に無い語で
            // 始まるファイル名を後続のフォーマットへ落とす型条件）——束縛すれば
            // 本の種別ラベルにもなる、というのが上乗せの利点にすぎない。
            // ここを外すと、`(@booktype)` を持つ既存ライブラリが「未束縛の予約語」
            // として設定を一切保存できなくなる。
            if keyword == .bookType { return false }
            if keepsStructuredColumns, keyword.hasStructuredColumn { return false }
            guard semanticBindings[keyword] == nil else { return false }
            return source.contains(keyword.rawValue)
        }
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
                                 priority: priority, kind: pattern.kind)
        }

        return LibrarySettingsSnapshot(
            libraryID: libraryID,
            settingsRevision: settingsRevision,
            displayName: displayName,
            bookTypeVocabulary: bookTypeVocabulary,
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
