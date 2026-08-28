//
//  パーサへ渡す設定のスナップショット [3.4][VT-01〜VT-03]。
//
//  **immutable な値型**。設定変更のたびに作り直してパーサへ渡す。パーサ側は
//  状態を持たない [A-01][VT-01]。生成コストを避けるため `libraryID` +
//  `settingsRevision` でキャッシュする [VT-02]。
//
import Foundation

public struct LibrarySettingsSnapshot: Sendable {
    public let libraryID: LibraryID
    /// キャッシュキー。設定変更で上げる [VT-02]。
    public let settingsRevision: Int

    /// `@libraryname` の照合値 [RW-04]。
    public let displayName: String
    /// `@librarytype` の照合値 [RW-01]。
    public let libraryTypeName: String
    /// 型付き照合の列挙候補 [9.2.2][TY-01]。
    public let allLibraryTypeNames: [String]
    public let allLibraryDisplayNames: [String]

    public let targetExtensions: Set<String>
    public let imageExtensions: Set<String>          // [IF-02]
    public let delimiters: DelimiterSet              // [9.3]
    public let protectedTokens: [CompiledProtectedToken]   // [9.2.3]

    /// 優先順に並んだファイル名フォーマット [FF-03]。
    public let filenameFormats: [CompiledFormat]
    /// フォルダ階層 → 割り当て [AL-01][AL-02][AL-03]。
    public let folderLevelAssignments: [Int: FolderLevelMappingSpec.Assignment]
    /// 優先順に並んだ巻数フォーマット [SE-21]。
    public let volumeFormats: [CompiledVolumePattern]

    /// セマンティック予約語 → ラベルグループ番号 [RW-13]。
    public let semanticBindings: [SemanticKeyword: Int]
    /// 既定 `"@series @volume"` [SE-33]。
    public let seriesTitleCompositionFormat: String
    public let maxLabelGroups: Int

    /// ファイル自身が持つメタデータを読むか [EM-06]。
    public let readsEmbeddedMetadata: Bool
    /// `ComicInfo.xml` の巻数をどちらの要素から取るか [EM-30]。
    public let comicInfoVolumeSource: ComicInfoVolumeSource
    /// ブックフォルダの「開く」を関連付けアプリに任せるか [IF-18][AS-06]。
    public let opensBookFolderWithApp: Bool

    public init(libraryID: LibraryID,
                settingsRevision: Int = 0,
                displayName: String = "",
                libraryTypeName: String = "",
                allLibraryTypeNames: [String] = [],
                allLibraryDisplayNames: [String] = [],
                targetExtensions: Set<String> = [],
                imageExtensions: Set<String> = [],
                delimiters: DelimiterSet = .default,
                protectedTokens: [CompiledProtectedToken] = [],
                filenameFormats: [CompiledFormat] = [],
                folderLevelAssignments: [Int: FolderLevelMappingSpec.Assignment] = [:],
                volumeFormats: [CompiledVolumePattern] = [],
                semanticBindings: [SemanticKeyword: Int] = [:],
                seriesTitleCompositionFormat: String = "@series @volume",
                maxLabelGroups: Int = AppLimits.Format.maxLabelGroups,
                readsEmbeddedMetadata: Bool = true,
                comicInfoVolumeSource: ComicInfoVolumeSource = .ask,
                opensBookFolderWithApp: Bool = false) {
        self.libraryID = libraryID
        self.settingsRevision = settingsRevision
        self.displayName = displayName
        self.libraryTypeName = libraryTypeName
        self.allLibraryTypeNames = allLibraryTypeNames
        self.allLibraryDisplayNames = allLibraryDisplayNames
        self.targetExtensions = targetExtensions
        self.imageExtensions = imageExtensions
        self.delimiters = delimiters
        self.protectedTokens = protectedTokens
        self.filenameFormats = filenameFormats
        self.folderLevelAssignments = folderLevelAssignments
        self.volumeFormats = volumeFormats
        self.semanticBindings = semanticBindings
        self.seriesTitleCompositionFormat = seriesTitleCompositionFormat
        self.maxLabelGroups = maxLabelGroups
        self.readsEmbeddedMetadata = readsEmbeddedMetadata
        self.comicInfoVolumeSource = comicInfoVolumeSource
        self.opensBookFolderWithApp = opensBookFolderWithApp
    }

    /// フォーマットのコンパイルに渡す文脈を組み立てる。
    public var compilationContext: FormatCompilationContext {
        FormatCompilationContext(delimiters: delimiters,
                                 maxLabelGroups: maxLabelGroups,
                                 allLibraryTypeNames: allLibraryTypeNames,
                                 allLibraryDisplayNames: allLibraryDisplayNames,
                                 semanticBindings: semanticBindings)
    }
}
