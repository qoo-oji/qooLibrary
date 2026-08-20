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

public struct VolumePattern: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// 正規表現。巻数は `(?<volume>…)` か、唯一のキャプチャグループから取る。
    public var source: String
    public var isEnabled: Bool
    public var priority: Int             // 登録順＝同長のときの決着に使う [SE-21]
    public var kind: VolumePatternKind

    public init(id: UUID = UUID(), source: String, isEnabled: Bool = true,
                priority: Int = 0, kind: VolumePatternKind = .volume) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.priority = priority
        self.kind = kind
    }
}

public struct CompiledVolumePattern: Sendable {
    public let id: UUID
    public let source: String
    public let kind: VolumePatternKind
    public let priority: Int
    let regex: SafeRegex
    let health: RegexPatternHealth

    public var isSeparator: Bool { kind == .separator }

    init(id: UUID, source: String, kind: VolumePatternKind, priority: Int,
         regex: SafeRegex, health: RegexPatternHealth) {
        self.id = id
        self.source = source
        self.kind = kind
        self.priority = priority
        self.regex = regex
        self.health = health
    }
}

extension CompiledVolumePattern: Equatable {
    /// `SafeRegex` は同値比較できないので、由来の定義で比べる。
    public static func == (lhs: CompiledVolumePattern, rhs: CompiledVolumePattern) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
            && lhs.kind == rhs.kind && lhs.priority == rhs.priority
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
                                     kind: pattern.kind, priority: pattern.priority,
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
