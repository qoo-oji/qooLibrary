//
//  JSON 取り込みの直前の写し [IE-13][JS-08][UD-03]。
//
//  取り込みは「重ねる」だけ [JS-05] だが、重ねた先の値（評価・保護・ラベルの
//  色やピン・シェルフの条件・ライブラリ設定）は**上書きされる**。⌘Z で
//  取り込み全体を 1 単位として戻すために、取り込みが触った行だけをここへ
//  控える——ライブラリ全体を写すのではなく、**触った行と、新しく作った行の
//  ID** を持つ。触っていない行は Undo でも触らない。
//
//  ## 「更新した行」と「作った行」を分けて持つ
//  更新した行は前の値へ書き戻し、作った行は削除する。1 つの一覧に混ぜると
//  「前の値が無い」ことを `nil` で表すしかなくなり、値が `nil` の列を持つ行
//  （`colorHex` など）と区別が付かない。
//
//  ## 行 ID は同じものへ戻る
//  取り込みが更新する行は消さないので ID は不変。作った行は削除するだけで、
//  Redo（取り込みをもう一度）は新しい ID で作り直す——取り込みは冪等なので
//  内容は同じになる。
//
//  ## `settingsRevision` は持たない
//  パーサのキャッシュ鍵 [VT-02] は単調増加でなければならない。Undo でも
//  「設定が変わった」ことに変わりはないので、戻すのではなく上げる。
//
import Foundation

/// 取り込みの直前の写し。`BackupRepository.import` が返し、
/// `BackupRepository.revertImport` が受け取る。
public struct ImportSnapshot: Sendable, Equatable {

    /// ライブラリ 1 件ぶん。取り込みはライブラリ単位で重ねる [JS-04]。
    public struct LibraryPart: Sendable, Equatable {
        /// `library` 行のうち取り込みが置き換える列。
        public struct SettingsRow: Sendable, Equatable {
            public var settingsJSON: String
            public var duplicateGrouping: String
            public var thumbnailsAlwaysHidden: Bool
            public var registeredTemplateJSON: String?

            public init(settingsJSON: String, duplicateGrouping: String,
                        thumbnailsAlwaysHidden: Bool, registeredTemplateJSON: String?) {
                self.settingsJSON = settingsJSON
                self.duplicateGrouping = duplicateGrouping
                self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
                self.registeredTemplateJSON = registeredTemplateJSON
            }
        }

        public struct FilenameFormatRow: Sendable, Equatable {
            public var source: String
            public var priority: Int
            public var isEnabled: Bool

            public init(source: String, priority: Int, isEnabled: Bool) {
                self.source = source
                self.priority = priority
                self.isEnabled = isEnabled
            }
        }

        public struct VolumeFormatRow: Sendable, Equatable {
            public var source: String
            public var priority: Int
            public var isEnabled: Bool
            public var kind: String
            /// `PatternRole` の生値 [MF-07]。**DB の行の写しなので非 Optional**
            /// ——取り込みの Undo は「ちょうど元へ戻す」ことが役目である。
            public var role: String

            public init(source: String, priority: Int, isEnabled: Bool, kind: String,
                        role: String = "volume") {
                self.source = source
                self.priority = priority
                self.isEnabled = isEnabled
                self.kind = kind
                self.role = role
            }
        }

        public struct FolderLevelRow: Sendable, Equatable {
            public var level: Int
            public var assignmentKind: String
            public var labelGroupIndex: Int?
            public var formatSource: String?

            public init(level: Int, assignmentKind: String,
                        labelGroupIndex: Int?, formatSource: String?) {
                self.level = level
                self.assignmentKind = assignmentKind
                self.labelGroupIndex = labelGroupIndex
                self.formatSource = formatSource
            }
        }

        public struct ProtectedTokenRow: Sendable, Equatable {
            public var pattern: String
            public var position: String
            public var isEnabled: Bool

            public init(pattern: String, position: String, isEnabled: Bool) {
                self.pattern = pattern
                self.position = position
                self.isEnabled = isEnabled
            }
        }

        /// `labelGroup` 行。取り込みが上書きする列だけを持つ。
        public struct FieldRow: Sendable, Equatable {
            public var id: FieldID
            public var name: String
            public var colorHexLight: String
            public var colorHexDark: String
            public var displayOrder: Int
            public var assignsAutomatically: Bool

            public init(id: FieldID, name: String, colorHexLight: String, colorHexDark: String,
                        displayOrder: Int, assignsAutomatically: Bool) {
                self.id = id
                self.name = name
                self.colorHexLight = colorHexLight
                self.colorHexDark = colorHexDark
                self.displayOrder = displayOrder
                self.assignsAutomatically = assignsAutomatically
            }
        }

        /// `label` 行。紐づけは持たない——取り込みが足す紐づけは、対象ファイルの
        /// `ManagedFileSnapshot` が「ちょうど戻す」ときに一緒に消える。
        public struct LabelRow: Sendable, Equatable {
            public var id: LabelID
            public var name: String
            public var colorHex: String?
            public var isPinned: Bool
            public var isHidden: Bool

            public init(id: LabelID, name: String, colorHex: String?,
                        isPinned: Bool, isHidden: Bool) {
                self.id = id
                self.name = name
                self.colorHex = colorHex
                self.isPinned = isPinned
                self.isHidden = isHidden
            }
        }

        /// `shelf` 行。条件は JSON のまま持つ——復号して型に戻すと、読めない
        /// 生値が既定へ落ちて「ちょうど戻す」にならない。
        public struct ShelfRow: Sendable, Equatable {
            public var id: ShelfID
            public var displayOrder: Int
            public var conditionJSON: String

            public init(id: ShelfID, displayOrder: Int, conditionJSON: String) {
                self.id = id
                self.displayOrder = displayOrder
                self.conditionJSON = conditionJSON
            }
        }

        /// `unresolvedFile.isIgnored` の前の値 [AL-33]。
        public struct IgnoreFlag: Sendable, Equatable {
            public var fileID: FileID
            public var isIgnored: Bool

            public init(fileID: FileID, isIgnored: Bool) {
                self.fileID = fileID
                self.isIgnored = isIgnored
            }
        }

        public var libraryID: LibraryID
        public var settings: SettingsRow
        public var filenameFormats: [FilenameFormatRow]
        public var volumeFormats: [VolumeFormatRow]
        public var folderLevels: [FolderLevelRow]
        public var protectedTokens: [ProtectedTokenRow]
        public var updatedFields: [FieldRow]
        public var insertedFieldIDs: [FieldID]
        public var updatedLabels: [LabelRow]
        public var insertedLabelIDs: [LabelID]
        public var updatedShelves: [ShelfRow]
        public var insertedShelfIDs: [ShelfID]
        /// 値を書き戻したファイルの、書き戻す前の全列 [ManagedFileSnapshot]。
        public var files: [ManagedFileSnapshot]
        public var unresolvedIgnored: [IgnoreFlag]

        public init(libraryID: LibraryID, settings: SettingsRow,
                    filenameFormats: [FilenameFormatRow], volumeFormats: [VolumeFormatRow],
                    folderLevels: [FolderLevelRow], protectedTokens: [ProtectedTokenRow],
                    updatedFields: [FieldRow], insertedFieldIDs: [FieldID],
                    updatedLabels: [LabelRow], insertedLabelIDs: [LabelID],
                    updatedShelves: [ShelfRow], insertedShelfIDs: [ShelfID],
                    files: [ManagedFileSnapshot], unresolvedIgnored: [IgnoreFlag]) {
            self.libraryID = libraryID
            self.settings = settings
            self.filenameFormats = filenameFormats
            self.volumeFormats = volumeFormats
            self.folderLevels = folderLevels
            self.protectedTokens = protectedTokens
            self.updatedFields = updatedFields
            self.insertedFieldIDs = insertedFieldIDs
            self.updatedLabels = updatedLabels
            self.insertedLabelIDs = insertedLabelIDs
            self.updatedShelves = updatedShelves
            self.insertedShelfIDs = insertedShelfIDs
            self.files = files
            self.unresolvedIgnored = unresolvedIgnored
        }
    }

    public var libraries: [LibraryPart]

    public init(libraries: [LibraryPart]) {
        self.libraries = libraries
    }

    /// 取り込みが 1 行も触らなかった（一致するライブラリが無かった）。
    public var isEmpty: Bool { libraries.isEmpty }
}

/// 取り込みの結果 [JS-08]。計画（何が起きたか）と、戻すための写しの対。
public struct ImportOutcome: Sendable, Equatable {
    public var plan: ImportPlan
    public var snapshot: ImportSnapshot

    public init(plan: ImportPlan, snapshot: ImportSnapshot) {
        self.plan = plan
        self.snapshot = snapshot
    }
}
