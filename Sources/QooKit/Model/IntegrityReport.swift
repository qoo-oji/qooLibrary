//
//  DB とファイルシステムの不整合 [RB-02][12章 §12.7]。
//
//  **走査がやることはここでやらない。** 「DB にあるが実体が無い」
//  「実体はあるが DB に無い」は `ScanEngine` の仕事で、あちらは対象拡張子・
//  ブックフォルダ・保管庫の規則を全部知っている——ここで同じ判定を書くと、
//  規則が 2 通りになって食い違う（このリポジトリが繰り返し踏んでいる形）。
//
//  ここが見るのは**走査では気づけない食い違い**だけである。
//
import Foundation

/// 整合性チェックの結果 [RB-02]。
///
/// ## 仕様書 §12.7 の `Report` から変えた点
///
/// | §12.7 の項目 | いま |
/// |---|---|
/// | `missingFiles` / `untrackedFiles` | **持たない**——走査そのもの（上記）|
/// | `labelCountMismatches` | **消滅**。非正規化列 `label.fileCount` は §19.13 #1 で撤去済みで、件数は毎回数える |
/// | `duplicateInodes` | **持たない**——`(volumeUUID, inode)` に UNIQUE 索引があり、構造的に起こらない |
/// | `brokenCoverRefs` | そのまま |
/// | `orphanFileLabels` | **`PRAGMA foreign_key_check` に畳んだ**。`fileLabel` は外部キーで守られているので、破れているなら制約ごと壊れている |
/// | `archiveMismatches` | そのまま |
public struct IntegrityReport: Sendable, Equatable {
    /// ユーザー指定カバー [CV-02] の複製が失われている行。
    ///
    /// **起きうる**——複製は DB の外（`usercovers/`）にあり、古い世代へ
    /// 復元すると「その頃は参照されていたが、以後の起動時の掃除で捨てられた」
    /// 複製への参照が蘇る [CV-06]。
    public var brokenCoverRefs: [IntegrityFinding]

    /// `isArchived` と実際の相対パスが食い違う行 [FA-05][SY-10]。
    ///
    /// 走査は `.qooarchive` の中かどうかで印を付け直すので、**オンラインの
    /// ライブラリでは自然に直る**。直らないのはオフラインのまま放置された
    /// ライブラリで、そこは走査が判定を避ける [R-01]。
    public var archiveMismatches: [IntegrityFinding]

    /// 持ち主を失った保護文字列 [PT-08]。
    ///
    /// **外部キーで守れない**——`ownerKind` / `ownerID` の多相参照なので
    /// 制約を張れず、`PRAGMA foreign_key_check` にも映らない。実際に
    /// ライブラリの登録解除で 36 件積み上がっていたことがある（移行
    /// `v11_orphanedProtectedTokens` で掃除した）。
    public var orphanedProtectedTokens: [IntegrityFinding]

    /// 外部キー制約が破れている行。**普通は空**——空でなければストアが
    /// 壊れているか、制約を切ったまま書いた経路がある。
    public var foreignKeyViolations: [IntegrityFinding]

    public init(brokenCoverRefs: [IntegrityFinding] = [],
                archiveMismatches: [IntegrityFinding] = [],
                orphanedProtectedTokens: [IntegrityFinding] = [],
                foreignKeyViolations: [IntegrityFinding] = []) {
        self.brokenCoverRefs = brokenCoverRefs
        self.archiveMismatches = archiveMismatches
        self.orphanedProtectedTokens = orphanedProtectedTokens
        self.foreignKeyViolations = foreignKeyViolations
    }

    public var isEmpty: Bool { totalCount == 0 }

    public var totalCount: Int {
        brokenCoverRefs.count + archiveMismatches.count
            + orphanedProtectedTokens.count + foreignKeyViolations.count
    }

    /// 直せる項目だけ [12章 §12.7: 修復は項目単位で選択、自動修復はしない]。
    public var repairableCount: Int {
        brokenCoverRefs.count + archiveMismatches.count + orphanedProtectedTokens.count
    }
}

/// 見つかった不整合 1 件。
public struct IntegrityFinding: Sendable, Equatable, Identifiable, Hashable {
    /// 直し方。**`foreignKeyViolations` には無い**——何が正しい状態なのかを
    /// アプリが決められない [12章 §12.7: 誤った一括修復でラベルを失うリスク]。
    public enum Repair: Sendable, Equatable, Hashable {
        /// カバーの参照を捨てて既定へ戻す [IV-03]。
        case clearCoverReference
        /// `isArchived` を実際の相対パスに合わせる [FA-05]。
        case matchArchiveFlagToPath(Bool)
        /// 持ち主を失った保護文字列を消す [PT-08]。
        case deleteProtectedToken
    }

    public var id: String
    /// 画面に出す説明。**ファイル名ではなく相対パス**——同じ名前が複数の
    /// フォルダにあるのが普通なので、名前だけでは特定できない。
    public var subject: String
    public var detail: String
    public var repair: Repair?

    public init(id: String, subject: String, detail: String, repair: Repair? = nil) {
        self.id = id
        self.subject = subject
        self.detail = detail
        self.repair = repair
    }
}
