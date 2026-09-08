//
//  フォーマット中のフィールド参照 [MT-12][RW-01〜RW-17]。
//
import Foundation

/// 予約語が指すフィールド。ラベルグループ番号は任意桁を許す [MT-12]。
public enum FieldRef: Sendable, Hashable, Codable {
    case title
    case series
    case author
    /// サークル・イベント・ジャンル・キーワード [RWI-02]。
    /// **構造化列を持たず、束縛先のフィールドへラベルとしてだけ流れる**
    /// ——`@author` が `managedFile.authorName` を持つのとはそこが違う。
    case studio
    case event
    case genre
    case keyword
    /// カスタム軸 2〜5 [MF-22]。**用途は利用者が決める**——フィールドを作って
    /// 名前を付け、参照名としてこれを束縛する。
    ///
    /// ## 撤去した `@labelgroupN` と何が違うか
    /// あちらは**フィールドの番号を直接参照**していたので、並べ替え・改名で
    /// 指す先が変わった。こちらは `SemanticKeyword` の case で、束縛
    /// （`semanticBindings`）が独立して追随する——**番号は軸の身元であって
    /// フィールドの番号ではない。**
    case keyword2
    case keyword3
    case keyword4
    case keyword5
    case volume
    /// 本の種別（一般コミック／同人誌…）。ファイル名の中の印（`(同人誌)`）と
    /// **語彙で照合し** [TY-01]、一致した値は**ラベルとして残る**。
    ///
    /// ## なぜ自由文字列にしないか [実測]
    /// 型条件を外して自由文字列にすると、プリセットの
    /// `(@mediatype) [@studio (@author)] @title …` が
    /// `(@event) [@studio (@author)] @title …` と**先頭以外まったく同じ形**に
    /// なり、優先順位が上の前者が `(C99)` のようなイベント名まで吸う。
    /// public ゴールデン 352 件のうち **48 件でイベントが取れなくなる**ことを
    /// 実際に測って確かめた。フォーマットの順序では解けない（2 本が同型のため）。
    case mediaType
    /// 出演者 [MF-02]。**構造化列を持たず、束縛先のフィールドへラベルとしてだけ流れる**
    /// ——`@studio` と同じ側である。
    case actor
    /// シーズン [MF-04]。型付き（`role = season` の正規表現セット）で、構造化列
    /// `seasonNumber` を持ち、**束縛すればラベルにもなる**（`@series` と同じ二重性）。
    /// 束縛できるようにしたのは段 C のコレクション分けのため [§21.4]。
    case season
    /// 話数 [MF-05]。型付き（`role = episode`）で、構造化列 `episodeNumber` のみ。
    /// **束縛しない**——`@volume` と同じ側である。
    case episode
    /// サブタイトル [MF-03]。自由文字列で、構造化列 `subtitle` のみ。
    /// `searchKey` に含める [SR-03]。**`@title` との同居を許す** [MF-16]。
    case subtitle
    /// 公開日・放送日・発行年 [MF-19]。型付き（`role = date`）で、構造化列
    /// `releaseDate`（**ISO 8601 の部分形**）のみ。**束縛しない** [MF-20]。
    case date
    /// 同一フォーマット内で複数書けるため出現順の連番で区別する [RW-03]。
    case ignore(Int)

    /// 自由文字列として照合するか [9.2.2]。`false` は型付き照合 [TY-01]。
    public var isFreeText: Bool {
        switch self {
        case .title, .series, .author, .studio, .event, .genre, .keyword, .ignore,
             .actor, .subtitle, .keyword2, .keyword3, .keyword4, .keyword5:
            return true
        case .volume, .mediaType, .season, .episode, .date:
            return false
        }
    }

    /// 抽出値を捨てるフィールド（照合にだけ使う）[RW-02][RW-04]。
    ///
    /// **`@mediatype` はここに含めない** [TY-01、2026-09-04]。
    ///
    /// ここが効くのは `FormatCompiler` の「1 つも抽出しないフォーマットを
    /// 拒む」検査 [FF-13] だけ——`(@mediatype)` の 1 本だけでも意味のある
    /// フォーマットになった、というのがこの変更の意味である。
    /// **値がラベルへ流れるのはここではなく `SemanticKeyword.mediaType` の
    /// 束縛による**ので、取り違えないこと（この 2 つは独立している）。
    public var discardsValue: Bool {
        switch self {
        case .ignore: return true
        default: return false
        }
    }

    /// フォーマット内での重複を許すか [RW-03]。`@ignore` のみ許す。
    public var allowsDuplicates: Bool {
        if case .ignore = self { return true }
        return false
    }
}

/// セマンティック予約語 [RW-13][RWI-02]。
///
/// **case を足すだけで拡張でき、スキーマ変更を伴わない**——束縛は
/// `settingsJSON.semanticBindings`（`[String: Int]`）に載るだけで、
/// 知らない綴りは読み飛ばされる。
///
/// ## 既定フィールドとの関係 [§19.2]
/// 既定 6 種（著者・サークル・ジャンル・イベント・キーワード・本の種別）は**この列挙が
/// そのまま身元になる**——表示名はライブラリごとに変えられるので、表示名を
/// 識別子にすると改名した瞬間にフォーマットと束縛が壊れる。`@series` だけは
/// 既定フィールドではなく、シリーズ名（構造化列）をラベルにも流したいときの
/// 任意の束縛として残る。
public enum SemanticKeyword: String, Sendable, Codable, CaseIterable, Hashable {
    case series = "@series"
    case author = "@author"
    case studio = "@studio"
    case event = "@event"
    case genre = "@genre"
    case keyword = "@keyword"
    /// カスタム軸 2〜5 [MF-22]。**既定フィールドには入れない**——入れると
    /// コミックの全ライブラリに空のフィールドが 4 つ生える。
    case keyword2 = "@keyword2"
    case keyword3 = "@keyword3"
    case keyword4 = "@keyword4"
    case keyword5 = "@keyword5"
    case mediaType = "@mediatype"
    /// [MF-02]。表示名は映像プリセットでは「出演」だが、身元はこの綴りである。
    case actor = "@actor"
    /// [MF-04]。構造化列と束縛の**両方**を持つ（`@series` と同じ）。
    case season = "@season"

    public var fieldRef: FieldRef {
        switch self {
        case .series: return .series
        case .author: return .author
        case .studio: return .studio
        case .event: return .event
        case .genre: return .genre
        case .keyword: return .keyword
        case .keyword2: return .keyword2
        case .keyword3: return .keyword3
        case .keyword4: return .keyword4
        case .keyword5: return .keyword5
        case .mediaType: return .mediaType
        case .actor: return .actor
        case .season: return .season
        }
    }

    /// 束縛が無くても値が残るか [RW-16]。
    ///
    /// `@series` は `seriesName`、`@author` は `authorName` という**構造化列**を
    /// 持つので、どのフィールドにも束縛されていなくても書く意味がある。
    /// 残る 4 種は列を持たないため、束縛が無ければ切り出した値は**捨てられる**
    /// ——照合には成功するのに何も残らない、という気づきにくい状態になる。
    public var hasStructuredColumn: Bool {
        switch self {
        case .series, .author, .season: return true
        case .studio, .event, .genre, .keyword, .mediaType, .actor,
             .keyword2, .keyword3, .keyword4, .keyword5: return false
        }
    }

    /// 既定フィールドとして全ライブラリに保証する 6 種 [§19.2]。**並び順が
    /// そのまま設定画面の既定の並びと配色の割り当て順になる。**
    /// `@series` を含まないのは、シリーズが構造化列であってフィールドでは
    /// ないため——束縛はできるが、既定では置かない。
    ///
    /// **`@mediatype` は末尾に足す。** 既定 1〜5 の番号を動かさないため
    /// ——番号はフィールドの身元ではないが、既存の設定・テストが番号で
    /// 引いている箇所があり、動かす利点が無い。
    public static let defaultFields: [SemanticKeyword] = [
        .author, .studio, .genre, .event, .keyword, .mediaType,
    ]
}

/// 予約語の綴りと `FieldRef` の対応表。
///
/// ## 予約語はここに並ぶものがすべて [v3 ステージ 5]
/// **`@labelgroupN` と `@libraryname` は撤去した。**
/// - `@labelgroupN`: 番号はフィールドの身元ではない（並べ替え・改名で指す先が
///   変わる）。既定フィールド 6 種は意味予約語で参照でき、それ以外のフィールドは
///   手で付けるためのもの——ファイル名から自動抽出する軸は既定の 6 種に閉じる。
/// - `@libraryname`: 用途が定まらないまま置かれていた [旧 RW-05] うえ、
///   表示名がフォルダ名へ自動追随するようになった [RG3-31] ので、**利用者が
///   Finder でフォルダを改名した瞬間に照合値が変わる**——黙って一致しなくなる。
public enum ReservedWordTable {
    /// 長い順に並べる（最長一致で読むため）[LX-01]。
    ///
    /// **セマンティック予約語はここに直接書かず `SemanticKeyword` から導く。**
    /// 2 箇所に書くと、case を足したのに字句解析が読めない（＝綴りを書いても
    /// 「不明な予約語」になる）という、気づきにくい食い違いが起きる。
    public static let entries: [(word: String, field: FieldRef)] = {
        let semantic = SemanticKeyword.allCases.map { (word: $0.rawValue, field: $0.fieldRef) }
        let others: [(word: String, field: FieldRef)] = [
            ("@volume", .volume),
            ("@ignore", .ignore(0)),          // 連番は字句解析側で振り直す [LX-03]
            ("@title", .title),
            ("@episode", .episode),           // [MF-05] 束縛しないのでここに書く
            ("@subtitle", .subtitle),         // [MF-03]
            ("@date", .date),                 // [MF-19]
        ]
        return (semantic + others).sorted { $0.word.count > $1.word.count }
    }()
}
