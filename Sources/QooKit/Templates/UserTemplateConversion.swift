//
//  ユーザー定義テンプレート ⇄ 編集草案 [LT-02][LT-03]。
//
//  **一覧・推奨・登録・編集はすべて草案で行う**（`UserTemplate.swift` の解説）。
//  プリセットは `TemplateInstantiation.draft(from:)`、ユーザー定義はここが
//  草案を作るので、そこから先の経路は 1 本で済む。
//
import Foundation

extension UserTemplateSettings {

    /// 編集草案から設定を取り出す [LT-02]。
    ///
    /// **揮発値（各 draft の `id`・`persistentID`）は落とす**——テンプレートは
    /// 「設定の雛形」であって特定のライブラリの行を指すものではない。
    /// `displayName` と `otherLibraryTypeNames` も落とす（型の解説の表）。
    public init(_ draft: LibrarySettingsDraft) {
        self.init(
            libraryTypeName: draft.libraryTypeName,
            thumbnailsAlwaysHidden: draft.thumbnailsAlwaysHidden,
            duplicateGrouping: draft.duplicateGrouping,
            targetExtensions: draft.targetExtensions,
            imageExtensions: draft.imageExtensions,
            delimiters: draft.delimiters,
            protectedTokens: draft.protectedTokens.map {
                ProtectedTokenSpec(pattern: $0.pattern, position: $0.position,
                                   isEnabled: $0.isEnabled)
            },
            fields: draft.fields.map {
                Field(index: $0.index, name: $0.name,
                      colorHexLight: $0.colorHexLight, colorHexDark: $0.colorHexDark,
                      assignsAutomatically: $0.assignsAutomatically)
            },
            semanticBindings: Dictionary(
                uniqueKeysWithValues: draft.semanticBindings.map { ($0.key.rawValue, $0.value) }),
            filenameFormats: draft.filenameFormats.map {
                FilenameFormat(source: $0.source, isEnabled: $0.isEnabled)
            },
            volumeFormats: draft.volumeFormats.map {
                VolumeFormat(source: $0.source, isEnabled: $0.isEnabled, kind: $0.kind)
            },
            folderLevels: draft.folderLevels.map { level in
                switch level.assignment {
                case .none:
                    FolderLevel(level: level.level, kind: .none)
                case .singleLabelGroup(let index):
                    FolderLevel(level: level.level, kind: .singleLabelGroup, field: index)
                case .format(let source):
                    FolderLevel(level: level.level, kind: .format, format: source)
                }
            },
            seriesTitleCompositionFormat: draft.seriesTitleCompositionFormat,
            readsEmbeddedMetadata: draft.readsEmbeddedMetadata,
            comicInfoVolumeSource: draft.comicInfoVolumeSource,
            opensBookFolderWithApp: draft.opensBookFolderWithApp)
    }

    /// 設定から編集草案を組み立てる [LT-03]。
    ///
    /// - Parameters:
    ///   - displayName: 登録先のフォルダ名 [RG3-31]。テンプレートは持たない。
    ///   - otherLibraryTypeNames: 自分以外のライブラリの型名。型付き照合
    ///     [TY-01] の列挙候補に要る。
    ///
    /// **未知の予約語は読み飛ばす**——撤去された `@labelgroupN` / `@libraryname`
    /// を含む古い文書が来ても、その束縛が落ちるだけで文書全体は読める
    /// [§19.8 の撤回]。
    ///
    /// **階層は番号順に並べる**——辞書由来ではないので順序は保たれるが、
    /// 取り込んだ文書が順不同なことはありうる（`draft(from:)` と同じ理由）。
    public func draft(displayName: String,
                      otherLibraryTypeNames: [String] = []) -> LibrarySettingsDraft {
        LibrarySettingsDraft(
            displayName: displayName,
            libraryTypeName: libraryTypeName,
            thumbnailsAlwaysHidden: thumbnailsAlwaysHidden,
            duplicateGrouping: duplicateGrouping,
            targetExtensions: targetExtensions,
            imageExtensions: imageExtensions,
            delimiters: delimiters,
            protectedTokens: protectedTokens.map {
                ProtectedToken(pattern: $0.pattern, position: $0.position,
                               isEnabled: $0.isEnabled)
            },
            fields: fields.map {
                FieldDraft(index: $0.index, name: $0.name,
                           colorHexLight: $0.colorHexLight, colorHexDark: $0.colorHexDark,
                           assignsAutomatically: $0.assignsAutomatically)
            },
            semanticBindings: semanticBindings.reduce(into: [SemanticKeyword: Int]()) {
                guard let keyword = SemanticKeyword(rawValue: $1.key) else { return }
                $0[keyword] = $1.value
            },
            filenameFormats: filenameFormats.map {
                FilenameFormatDraft(source: $0.source, isEnabled: $0.isEnabled)
            },
            volumeFormats: volumeFormats.map {
                VolumeFormatDraft(source: $0.source, isEnabled: $0.isEnabled, kind: $0.kind)
            },
            folderLevels: folderLevels
                .sorted { $0.level < $1.level }
                .compactMap { level in
                    let assignment: FolderLevelDraft.Assignment
                    switch level.kind {
                    case .none:
                        // **`Assignment.none` と明示する。** 素の `.none` は
                        // Swift が `Optional.none` と解釈する（このコードベースで
                        // 4 度踏んでいる罠）。
                        assignment = FolderLevelDraft.Assignment.none
                    case .singleLabelGroup:
                        guard let field = level.field else { return nil }
                        assignment = .singleLabelGroup(index: field)
                    case .format:
                        guard let source = level.format else { return nil }
                        assignment = .format(source: source)
                    }
                    return FolderLevelDraft(level: level.level, assignment: assignment)
                },
            seriesTitleCompositionFormat: seriesTitleCompositionFormat,
            readsEmbeddedMetadata: readsEmbeddedMetadata,
            comicInfoVolumeSource: comicInfoVolumeSource,
            opensBookFolderWithApp: opensBookFolderWithApp,
            otherLibraryTypeNames: otherLibraryTypeNames)
    }
}

extension UserTemplate {

    /// 編集草案からテンプレートを作る [LT-02]（「テンプレートとして保存…」）。
    public init(name: String, from draft: LibrarySettingsDraft) {
        self.init(name: name, settings: UserTemplateSettings(draft))
    }

    /// 別名で保存する [ユーザー要望、2026-09-04]。
    ///
    /// **新しい身元を振る。** 元がプリセットでもユーザー定義でも同じ——
    /// 「別名で保存」は複製であって上書きではない。プリセットを編集した草案が
    /// ここへ来ることで、**プリセット本体は決して書き換わらない**まま
    /// [LT-05]、その場で弄って保存できる。
    public func savedAs(name: String, settings: UserTemplateSettings,
                        now: Date = Date()) -> UserTemplate {
        UserTemplate(id: UUID(), name: name, version: 1,
                     createdAt: now, updatedAt: now, settings: settings)
    }

    /// 同じ身元のまま更新する（上書き保存）。**版を 1 つ進める。**
    public func updated(name: String? = nil, settings: UserTemplateSettings,
                        now: Date = Date()) -> UserTemplate {
        UserTemplate(id: id, name: name ?? self.name, version: version + 1,
                     createdAt: createdAt, updatedAt: now, settings: settings)
    }
}
