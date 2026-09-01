//
//  埋め込みメタデータとファイル名・フォルダ名の優先解決 [04章 §4.10][EM-03〜EM-05]。
//
//  **優先順位は「どこから読んだか」ではなく「どちらの値を採るか」という意味の
//  規則**で、実ファイルへのアクセスを伴わない。ここに置けばゴールデンテストが
//  標本の `EmbeddedMetadata` を直接与えて固定でき、アーカイブを作らずに
//  全組み合わせを試せる。
//
import Foundation

public enum EmbeddedMetadataMerge {

    /// フォルダ名・ファイル名から解決した結果へ、メタデータを**フィールド単位で**
    /// 上書きする [EM-04]。
    ///
    /// メタデータが持たないフィールドは、下の層で得た値をそのまま残す——
    /// `Series` しか持たない `ComicInfo.xml` は実在し、そこで巻数まで捨てると
    /// ファイル名から読めていたはずの巻数を失う。
    public static func apply(_ metadata: EmbeddedMetadata?,
                             to resolved: FolderLabelResolver.ResolvedLabels,
                             settings: LibrarySettingsSnapshot) -> FolderLabelResolver.ResolvedLabels {
        guard let metadata, !metadata.isEmpty else { return resolved }

        var title = resolved.title
        var seriesName = resolved.seriesName
        var volume = resolved.volume
        var authorName = resolved.authorName
        var labels = resolved.labels

        if let value = metadata.title { title = value }
        if let value = metadata.series { seriesName = value }
        // 衝突していて未確定のときは**巻数だけ**下の層の値を使う [EMM-07][VM3-03]。
        if let value = metadata.volume {
            volume = VolumeValue.numeric(value, raw: metadata.volumeRaw ?? Self.format(value))
        }
        if !metadata.authors.isEmpty {
            authorName = metadata.authors.joined(separator: Self.authorSeparator)
        }

        // 意味束縛でラベルグループへ流しているフィールドは、ラベル側も差し替える
        // [EMM-03]。**グループごと置き換える**——フォルダ名から得た値を残すと、
        // 同じ意味の値の出どころが 2 つある状態になる。
        if let group = settings.semanticBindings[.author], !metadata.authors.isEmpty {
            labels[group] = metadata.authors           // [EMM-04] 1 人ずつ別のラベルにする
        }
        if let group = settings.semanticBindings[.series], let series = metadata.series {
            labels[group] = [series]
        }

        return FolderLabelResolver.ResolvedLabels(
            labels: labels,
            title: title,
            seriesName: seriesName,
            volume: volume,
            authorName: authorName,
            matchedFormatID: resolved.matchedFormatID,
            nearestFormat: resolved.nearestFormat,
            libraryTypeMismatch: resolved.libraryTypeMismatch,
            folderProvidedGroups: resolved.folderProvidedGroups)
    }

    /// 表示用に著者を 1 つの文字列へ畳むときの区切り [EMM-04]。
    /// `ComicInfo.xml` の `Writer` と同じ書式にする（往復しても形が変わらない）。
    public static let authorSeparator = ", "

    /// 原文表記を持たないときに値から作る。`3.0` → `3`。
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// このファイルを「未解決」[AL-31] に数えるか。
    ///
    /// **メタデータから何か取れたなら数えない。**未解決の意味は「ラベルも
    /// タイトルも付かないまま埋もれる」ことであって、「ファイル名フォーマットに
    /// 一致しなかった」ことではない。`ComicInfo.xml` を持つ商業コミックは
    /// ファイル名が自由でも中身から正しく解釈できる。
    public static func isUnresolved(_ resolved: FolderLabelResolver.ResolvedLabels,
                                    metadata: EmbeddedMetadata?) -> Bool {
        if let metadata, !metadata.isEmpty { return false }
        return resolved.matchedFormatID == nil && resolved.labels.isEmpty
    }
}
