//
//  巻数フォーマット [10.2 節][SE-10][SE-21][SE-23][CR-20]。
//
//  **記法は正規表現**（2026-08 の仕様変更）。以前は `??`（数字）と `<space>`（空白
//  1 個以上）という独自のメタ記号だったが、`vol` / `Vol` / `VOL` / `volume` の揺れを
//  1 本で書けず、既定セットが 19 本に膨れていた。旧記法からの変換は
//  `LegacyVolumeNotation` が行う。
//
import Foundation

/// 巻数フォーマットの種別。
///
/// 以前は「序列巻数」（`上巻` = 1, `下巻` = 3 のように順序値を持つ巻数）という
/// 概念があったが、2026-08 の仕様変更で廃止し、**巻数を持たず「シリーズ名を切る」
/// ためだけに使う種別**へ置き換えた [ユーザー判断]。
///
/// 種別は**明示的に持つ**。キャプチャグループの有無では判定できない——
/// `総集編([0-9]+)` は区切り専用なのにキャプチャを持つ。
public enum VolumePatternKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// 巻数を取り出す。キャプチャグループの値が巻数になる。
    case volume
    /// シリーズ名を切るだけ。巻数は `.none` のままになる。
    case separator
}

/// 正規表現セットの役割 [MF-07][MF-08]。**`volumeFormat.role` 列に載る綴り。**
///
/// 巻数・シーズン・話数・日付は、どれも「フォーマットの中で型付きに照合し、
/// 一致した範囲から値を取り出す」という**同じ形**をしている。テーブルを 4 つに
/// 分けず 1 つの表に同居させるのは、編集 UI・草案・JSON・差分適用 [LT-13] の
/// すべてが `volumeFormats` を 1 系統として扱っているため——増やすと同じ配線が
/// 4 箇所に要る。
public enum PatternRole: String, Sendable, Codable, Hashable, CaseIterable {
    /// `@volume`。既定。
    case volume
    /// `@season` [MF-04]。
    case season
    /// `@episode` [MF-05]。
    case episode
    /// `@date` [MF-19]。値は数値ではなく **ISO 8601 の部分形**。
    case date

    /// 型条件に「素の数字表記」を含めるか [SE-24][MF-21]。
    ///
    /// `@volume` は `作品名 01` を拾うために必要で [SE-24]、`@episode` も絶対通し番号
    /// （`作品名 001`）のために同じ扱いにする。**`@season` と `@date` は含めない**
    /// ——4 桁や 2 桁の数字が何でもシーズン・年号になると、解像度（`1080`）や
    /// 作品名の数字を拾う。Jellyfin が話数の解析で踏んでいる形である（#3669）。
    public var allowsBareDigits: Bool {
        switch self {
        case .volume, .episode: return true
        case .season, .date:    return false
        }
    }
}

public struct VolumePattern: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// 正規表現。巻数は `(?<volume>…)` か、唯一のキャプチャグループから取る。
    public var source: String
    public var isEnabled: Bool
    public var priority: Int             // 登録順＝同長のときの決着に使う [SE-21]
    public var kind: VolumePatternKind
    /// どの予約語のためのパターンか [MF-07]。`kind` とは**別の軸**である
    /// ——`kind` は「値を取り出すか、切るだけか」、`role` は「どのフィールド用か」。
    /// `.separator` は `@volume` 専用なので、`role != .volume` の行が
    /// `.separator` を持つことはない（設定画面が出させない）。
    public var role: PatternRole

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                priority: Int = 0, kind: VolumePatternKind = .volume,
                role: PatternRole = .volume) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.priority = priority
        self.kind = kind
        self.role = role
    }

    /// 既定値を補うデコード。**`role` を持たない古い文書**（v19 より前の JSON
    /// バックアップ・`volume-sets.json`・ユーザー定義テンプレート）を読めるようにする
    /// ——非 Optional のまま合成の `init(from:)` に任せると `keyNotFound` で
    /// **文書全体の取り込みが失敗する**（`LibrarySettingsPayload` で踏んだ罠）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(String.self, forKey: .source)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        kind = try c.decodeIfPresent(VolumePatternKind.self, forKey: .kind) ?? .volume
        role = try c.decodeIfPresent(PatternRole.self, forKey: .role) ?? .volume
    }
}

public struct CompiledVolumePattern: Sendable {
    public let id: UUID
    public let source: String
    public let kind: VolumePatternKind
    public let role: PatternRole
    public let priority: Int
    let regex: SafeRegex
    let health: RegexPatternHealth

    public var isSeparator: Bool { kind == .separator }
    /// このパターンが名前で引けるキャプチャを持つか [MF-06]。
    public var namedGroups: Set<String> { regex.namedGroups }

    init(id: UUID, source: String, kind: VolumePatternKind, role: PatternRole,
         priority: Int, regex: SafeRegex, health: RegexPatternHealth) {
        self.id = id
        self.source = source
        self.kind = kind
        self.role = role
        self.priority = priority
        self.regex = regex
        self.health = health
    }
}

extension CompiledVolumePattern: Equatable {
    /// `SafeRegex` は同値比較できないので、由来の定義で比べる。
    public static func == (lhs: CompiledVolumePattern, rhs: CompiledVolumePattern) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
            && lhs.kind == rhs.kind && lhs.role == rhs.role && lhs.priority == rhs.priority
    }
}

public enum VolumePatternCompiler {

    /// 1 本をコンパイルする。**正規表現として読めなければ `nil`**。
    ///
    /// 保存時に `LibrarySettingsDraft.validate()` が弾くので、DB に読めない
    /// パターンが入ることは無い想定。ここで落とすのは最後の砦。
    public static func compile(_ pattern: VolumePattern,
                               health: RegexPatternHealth) -> CompiledVolumePattern? {
        guard let regex = try? SafeRegex(pattern.source) else { return nil }
        return CompiledVolumePattern(id: pattern.id, source: pattern.source,
                                     kind: pattern.kind, role: pattern.role,
                                     priority: pattern.priority,
                                     regex: regex, health: health)
    }

    /// 有効なものだけを登録順に並べてコンパイルする。
    ///
    /// **同じ `health` を共有する。**ある走査で打ち切られたパターンを、同じ設定の
    /// 別の照合経路（`@volume` の型付き照合とシリーズ抽出）でも避けるため。
    public static func compileAll(_ patterns: [VolumePattern]) -> [CompiledVolumePattern] {
        let health = RegexPatternHealth()
        return patterns
            .filter(\.isEnabled)
            .sorted { $0.priority < $1.priority }
            .compactMap { compile($0, health: health) }
    }
}
