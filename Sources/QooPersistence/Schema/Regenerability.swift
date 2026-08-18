//
//  再生成可能性の宣言 [MG-20〜MG-23][B-13][MG-25]。
//
//  SwiftData 前提の `@Regenerable` プロパティラッパは使わない。**型に宣言させ、
//  テストで網羅性を検証する**——文字列の走査より確実で、列を足したときに黙って
//  漏れない。
//
//  ここに宣言しなかった列は「再生成不可能」とみなされる。再生成不可能な列は
//  JSON エクスポートに漏れなく含めなければならない [MG-22][MG-23]。
//
import Foundation
import GRDB

public protocol RegenerabilityDeclaring: Sendable {
    static var databaseTableName: String { get }
    /// 再生成できる列。スキャン・パース・サムネイル生成で作り直せるもの [MG-21]。
    static var regenerableColumns: Set<String> { get }
    /// 再生成できないが、JSON へ出す必要も無い列（内部の識別子・外部キー等）。
    static var internalColumns: Set<String> { get }
}

extension ManagedFileRecord: RegenerabilityDeclaring {
    public static let regenerableColumns: Set<String> = [
        "normalizedName", "searchKey",
        "seriesName", "seriesKey",
        "volumeNumber", "volumeKind", "volumeRaw",
        "authorName",
        "isBookFolder",
        "pageCount", "subfolderCount", "firstImageWidth", "firstImageHeight",
        "lastParsedFormatID", "libraryTypeMismatch",
        // カバー画像は `coverImageSource == 'auto'` のときだけ再生成可能。
        // 列としては「再生成可能」に分類し、`coverImageSource` の値で守る [IV-03]。
        "coverImageRef",
        // `titleOrigin == 'auto'` のタイトルは再生成可能。手動編集は上書きしない
        // [RP-11]——`applyParsedFields` の SQL が `titleOrigin` を見て守る。
        "title",
    ]
    public static let internalColumns: Set<String> = [
        "id", "libraryId", "inode", "volumeUUID",
    ]
}

extension LabelRecord: RegenerabilityDeclaring {
    /// `fileCount` は非正規化キャッシュ [DB-02]。`normalizedName` は原文から導ける。
    public static let regenerableColumns: Set<String> = ["fileCount", "normalizedName"]
    public static let internalColumns: Set<String> = ["id", "labelGroupId"]
}

extension LabelGroupRecord: RegenerabilityDeclaring {
    /// グループ名・色はユーザーの設定。再生成できない [MG-22]。
    public static let regenerableColumns: Set<String> = []
    public static let internalColumns: Set<String> = ["id", "libraryId"]
}

extension FileLabelRecord: RegenerabilityDeclaring {
    /// `origin == 'auto'` の紐づけだけが再生成可能。`manual` と `manuallyRemoved` は
    /// **再生成不可能** [MG-22][RC-04]——列ではなく値で分かれるので、
    /// JSON へは `origin` ごと出す必要がある。
    public static let regenerableColumns: Set<String> = ["assignedAt"]
    public static let internalColumns: Set<String> = ["managedFileId", "labelId"]
}

extension LibraryRecord: RegenerabilityDeclaring {
    public static let regenerableColumns: Set<String> = [
        "resolvedPath",        // ブックマークから解決し直せる
        "lastFSEventID", "lastFullScanAt", "isOnline", "isReadOnlyDueToFS",
        "settingsRevision", "libraryTypeVersion",
    ]
    public static let internalColumns: Set<String> = ["id", "libraryTypeId", "bookmarkData"]
}

/// 検証対象の型を 1 箇所に集める。**新しいレコード型を足したらここへ追加する。**
public enum RegenerabilityRegistry {
    public static let declaringTypes: [any RegenerabilityDeclaring.Type] = [
        ManagedFileRecord.self,
        LabelRecord.self,
        LabelGroupRecord.self,
        FileLabelRecord.self,
        LibraryRecord.self,
    ]

    /// 実際のテーブルの列名を読む。宣言と食い違えばテストが落ちる。
    public static func actualColumns(_ db: Database, table: String) throws -> Set<String> {
        Set(try db.columns(in: table).map(\.name))
    }
}
