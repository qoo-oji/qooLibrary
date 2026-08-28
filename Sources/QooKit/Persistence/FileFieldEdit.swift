//
//  右ペインから書き換えるフィールド [RP-10〜RP-12][CV-02〜CV-08]。
//
//  **1 つの値型にまとめてある。** タイトルだけを変える編集 [RP-10] と、
//  ファイル名から導き直す再取得 [RP-12] は「書き換える列の数が違うだけの同じ
//  操作」なので、別々の API にすると Undo が対称にならない（`SetRatingCommand`
//  を単発と「全巻に適用」で共有しているのと同じ考え方）。変更前の状態も
//  同じ型で持てるので、`undo()` は「前の値をそのまま書き戻す」で済む。
//
import Foundation

/// タイトル・シリーズ名・巻数・著者の書き換え 1 件ぶん [RP-10〜RP-12]。
///
/// **`seriesKey` は持たない。** 正規化は書き込み側（リポジトリ）が導出する
/// [3.8 節: 正規化は `TextNormalizer` のみが行う]——呼び出し側に持たせると、
/// 表記ゆれの畳み込みが 2 箇所に散り、黙って別のシリーズになる。
public struct FileFieldEdit: Sendable, Hashable {
    public var title: String?
    /// 手動編集なら `.manual` [RP-11]。以後の自動上書きから守られる。
    public var titleOrigin: ValueOrigin
    public var seriesName: String?
    public var volume: VolumeValue
    public var authorName: String?

    public init(title: String?, titleOrigin: ValueOrigin, seriesName: String?,
                volume: VolumeValue, authorName: String?) {
        self.title = title
        self.titleOrigin = titleOrigin
        self.seriesName = seriesName
        self.volume = volume
        self.authorName = authorName
    }

    /// いまの行の値をそのまま写す（Undo の「変更前」と、部分的な書き換えの土台）。
    public init(_ row: FileRow) {
        self.init(title: row.title, titleOrigin: row.titleOrigin,
                  seriesName: row.seriesName, volume: row.volume,
                  authorName: row.authorName)
    }

    /// タイトルだけを手動値へ差し替えた版 [RP-10][RP-11]。
    ///
    /// 空白のみの入力は `nil`（未設定）として扱う——`titleOrigin` は `.manual`
    /// のままなので、**「自動抽出値を使わない」という意思表示は残る**
    /// [ユーザーが明示的に空にした、と「まだ何も無い」を区別する]。
    public func settingTitle(_ newTitle: String) -> FileFieldEdit {
        var copy = self
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? nil : trimmed
        copy.titleOrigin = .manual
        return copy
    }
}

/// カバー画像の割り当て [CV-02][CV-06][CV-07]。
///
/// `ref` は **複製の名前であって絶対パスではない** [CL-05]——置き場所を決めるのは
/// 保存側で、DB は参照だけを持つ。`source` が `.userSpecified` 以外のとき
/// `ref` は意味を持たない。
public struct CoverAssignment: Sendable, Hashable {
    public var source: CoverSource
    public var ref: String?

    public init(source: CoverSource, ref: String?) {
        self.source = source
        self.ref = ref
    }

    /// 自動抽出へ戻した状態 [CV-07]。
    public static let automatic = CoverAssignment(source: .auto, ref: nil)

    /// いまの行の割り当てを写す（Undo の「変更前」）。
    public init(_ row: FileRow) {
        self.init(source: row.coverImageSource, ref: row.coverImageRef)
    }

    public static func userSpecified(ref: String) -> CoverAssignment {
        CoverAssignment(source: .userSpecified, ref: ref)
    }
}
