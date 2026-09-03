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
        // 実体から読み直せるもの。走査が必ず上書きするので、JSON に持つと
        // **古い値で正しい観測を上書きする**危険だけが残る [MG-21]。
        "fileSize", "createdAt", "modifiedAt",
        "normalizedName", "searchKey", "titleKey",
        "seriesKey",
        "isBookFolder",
        "pageCount", "subfolderCount", "firstImageWidth", "firstImageHeight",
        "lastParsedFormatID", "libraryTypeMismatch",
        // 埋め込みメタデータ [EM-10]。ファイルから読み直せるので JSON には持たない
        // ——持つと、書き出した後にファイル側を直しても古い値で上書きされる。
        "metadataStamp", "metadataSource", "metadataJSON", "hasVolumeConflict",
        // カバー画像は `coverImageSource == 'auto'` のときだけ再生成可能。
        // 列としては「再生成可能」に分類し、`coverImageSource` の値で守る [IV-03]。
        "coverImageRef",
        // **基本情報の 4 つは、保護されていないときだけ再生成可能** [PR-01]。
        // 列としては「再生成可能」に分類し、`protectedScopes` の値で守る
        // （カバー画像を `coverImageSource` で守るのと同じ形）——`title` だけ
        // 出して他を落とすと、保護したシリーズ名が復元で失われる。
        "title", "seriesName", "volumeNumber", "volumeKind", "volumeRaw", "authorName",
    ]
    public static let internalColumns: Set<String> = [
        "id", "libraryId", "inode", "volumeUUID",
    ]
}

extension LabelRecord: RegenerabilityDeclaring {
    /// `normalizedName` は原文から導ける。**件数の列はもう無い** [DB-02 撤回]
    /// ——非正規化をやめ、表示のたびに数える [§19.13 #1]。
    ///
    /// **`isHidden` は再生成できない** [LA3-02]——「このラベルは出したくない」
    /// という人の判断で、走査からは導けない。
    public static let regenerableColumns: Set<String> = ["normalizedName"]
    public static let internalColumns: Set<String> = ["id", "labelGroupId"]
}

extension FieldRecord: RegenerabilityDeclaring {
    /// グループ名・色はユーザーの設定。再生成できない [MG-22]。
    public static let regenerableColumns: Set<String> = []
    public static let internalColumns: Set<String> = ["id", "libraryId"]
}

extension FileLabelRecord: RegenerabilityDeclaring {
    /// **保護されていないフィールドの紐づけだけが再生成可能** [PR-01][MG-22]。
    /// 保護は紐づけではなく `managedFile.protectedScopes` にあるので、
    /// 出す／出さないの判定は書き出し側（`SQLiteBackupRepository`）が行う。
    public static let regenerableColumns: Set<String> = ["assignedAt"]
    public static let internalColumns: Set<String> = ["managedFileId", "labelId"]
}

extension UnresolvedFileRecord: RegenerabilityDeclaring {
    /// **`isIgnored` だけが再生成できない** [AL-33][MG-22]。「このファイルは
    /// どのフォーマットにも当てはまらないと判断した」という利用者の意思表示で、
    /// 走査からは作り直せない——`origin == 'manual'` と同じ性質。
    ///
    /// 行の存在そのもの（＝未解決であること）と `filename` / `detectedAt` は
    /// 走査が作り直す。`nearestFormat*` はパーサが出す推定値。
    public static let regenerableColumns: Set<String> = [
        "filename", "detectedAt", "nearestFormatSource", "nearestFormatReach",
    ]
    public static let internalColumns: Set<String> = ["id", "libraryId", "managedFileId"]
}

extension LibraryRecord: RegenerabilityDeclaring {
    public static let regenerableColumns: Set<String> = [
        "resolvedPath",        // ブックマークから解決し直せる
        // 差分スキャンの起点 [SY-02][WA-10]。**JSON へ出してはならない** —
        // 別のマシンで取った書き出しを取り込むと、そこにあった起点を
        // 「このボリュームのもの」として信じてしまい、非起動中の変更を
        // 取りこぼす。取り込み後は 0/NULL のままフルスキャンへ落ちるのが正しい。
        "lastFSEventID", "fsEventsUUID",
        "lastFullScanAt", "isOnline", "isReadOnlyDueToFS",
        "settingsRevision", "libraryTypeVersion",
    ]
    public static let internalColumns: Set<String> = ["id", "libraryTypeId", "bookmarkData"]
}

extension ShelfRecord: RegenerabilityDeclaring {
    /// **1 列も再生成できない** [SH-12][MG-22]。名前も条件も並び順も利用者が
    /// 作ったもので、走査からは作り直せない——だから JSON バックアップへ
    /// 漏れなく出す必要がある。`createdAt` だけは内部の手がかりで、
    /// 復元時は取り込んだ時刻で構わない。
    public static let regenerableColumns: Set<String> = []
    public static let internalColumns: Set<String> = ["id", "libraryId", "createdAt"]
}

/// 検証対象の型を 1 箇所に集める。**新しいレコード型を足したらここへ追加する。**
public enum RegenerabilityRegistry {
    public static let declaringTypes: [any RegenerabilityDeclaring.Type] = [
        ManagedFileRecord.self,
        LabelRecord.self,
        FieldRecord.self,
        FileLabelRecord.self,
        LibraryRecord.self,
        UnresolvedFileRecord.self,
        ShelfRecord.self,
    ]

    /// 実際のテーブルの列名を読む。宣言と食い違えばテストが落ちる。
    public static func actualColumns(_ db: Database, table: String) throws -> Set<String> {
        Set(try db.columns(in: table).map(\.name))
    }
}
