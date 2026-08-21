//
//  ファイル自身が持つメタデータの読み取り結果 [8.11 節][EM-01〜EM-10]。
//
//  **実ファイルには触らない値型**。取り出し（アーカイブを開く、PDF を開く）は
//  `QooInfrastructure` の仕事で、ここにはバイト列を解釈した結果だけが来る [A-01]。
//  この分離のおかげで、解釈の規則はアーカイブを作らずにテストで固定できる。
//
import Foundation

/// 1 ファイルぶんの埋め込みメタデータ。
///
/// **「持っていない」と「空」を区別しない** [EMM-02]。`ComicInfo.xml` の既定値は
/// 空文字（`Volume` は `-1`）で、書き出したツールが埋めなかっただけのことが多い。
/// どちらも `nil` に畳んで扱う。
public struct EmbeddedMetadata: Sendable, Hashable, Codable {

    /// どの形式から読んだか。診断とデバッグのためだけに持つ——
    /// **優先順位は出どころで変えない**（メタデータはどれも同じ重み）。
    public enum Source: String, Sendable, Hashable, Codable, CaseIterable {
        case comicInfo, epub, pdf
    }

    /// `ComicInfo.xml` の `Number` と `Volume` が食い違ったときだけ持つ [EM-26]。
    ///
    /// **どちらが巻数かは機械的に決められない**（05章 §5.7）。Komga は `Number`、
    /// Kavita は `Volume` を巻数として扱う。値を捨てずに両方を運び、
    /// ユーザーの判断を待つ。
    public struct VolumeConflict: Sendable, Hashable, Codable {
        public let number: Double
        public let numberRaw: String
        public let volume: Double
        public let volumeRaw: String

        public init(number: Double, numberRaw: String, volume: Double, volumeRaw: String) {
            self.number = number
            self.numberRaw = numberRaw
            self.volume = volume
            self.volumeRaw = volumeRaw
        }
    }

    public let source: Source
    public let title: String?
    public let series: String?
    /// 確定した巻数。衝突していて未確定なら `nil` で、`volumeConflict` が非 nil になる。
    public let volume: Double?
    /// 巻数の原文表記。`VolumeValue.raw` に入れて出力書式 [CR-23] で使う。
    public let volumeRaw: String?
    /// 著者。カンマ区切りや複数要素は分割済み [EM-27]。
    public let authors: [String]
    public let volumeConflict: VolumeConflict?

    public init(source: Source,
                title: String? = nil,
                series: String? = nil,
                volume: Double? = nil,
                volumeRaw: String? = nil,
                authors: [String] = [],
                volumeConflict: VolumeConflict? = nil) {
        self.source = source
        self.title = title.flatMap(Self.cleaned)
        self.series = series.flatMap(Self.cleaned)
        self.volume = volume
        self.volumeRaw = volumeRaw.flatMap(Self.cleaned)
        self.authors = authors.compactMap(Self.cleaned)
        self.volumeConflict = volumeConflict
    }

    /// 4 つのフィールドが 1 つも埋まっていない。**読み取れたが中身が無い**状態で、
    /// キャッシュには残す（「読んだが無かった」を「まだ読んでいない」と
    /// 取り違えると、毎回開き直すことになる [SE3-25]）。
    public var isEmpty: Bool {
        title == nil && series == nil && volume == nil && authors.isEmpty && volumeConflict == nil
    }

    /// 前後の空白を落とし、空になったら `nil` にする。
    static func cleaned(_ value: String) -> String? {
        let trimmed = TextNormalizer.trimWhitespace(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `ComicInfo.xml` の巻数をどちらの要素から取るか [EM-30]。ライブラリ単位の設定。
public enum ComicInfoVolumeSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// 食い違ったらユーザーに確認する（既定）。
    case ask
    /// 常に `Number` を採る（Komga・公式スキーマの流儀）。
    case number
    /// 常に `Volume` を採る（Kavita の流儀）。
    case volume
}
