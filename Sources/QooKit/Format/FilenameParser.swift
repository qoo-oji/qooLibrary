//
//  フォーマット群の評価と意味づけ [4.8][4.9]。
//
import Foundation

/// 「最も近いフォーマット」の推定 [UR2-05][AL-32][PW-02]。
///
/// **比較は「満たした要素の数 → 到達位置」の順**［ユーザー判断、2026-09-01］。
/// 要件の文言は「照合が最も進んだ入力位置が最大のもの」だったが、実測すると
/// その指標は**飽和する**——自由文字列フィールドに入った時点で走査位置が入力の
/// 末尾へ届くため、`@title (@genre)` と `[@circle] @title @volume` がどちらも
/// 「16/16 文字まで到達」で同点になり、登録順で前者が勝つ（構造的には後者の
/// ほうが近い）。要素数を第一キーにすると、この取り違えが解ける。
public struct NearestFormat: Sendable, Equatable {
    public let formatID: UUID
    /// 満たしたフォーマット要素の数。**比較の第一キー**。
    public let satisfiedNodes: Int
    /// 照合が最も進んだ**原文**の位置（マスク後の添字ではない）。第二キー。
    ///
    /// 原文へ写してから返すのは、保存先（`unresolvedFile.nearestFormatReach`）と
    /// 表示側が保護文字列のマスクを知らずに使えるようにするため [PT-03]。
    public let reachedIndex: Int
}

/// 1 回の照合の全体。**一致しなかったときの「最も近いフォーマット」を副産物として
/// 返す** [UR2-05]。
///
/// 別の呼び出しで求め直さないのが要点——`parse` は一致しなければ全フォーマットを
/// 試し終えているので、そこで拾えば追加の走査は 1 回も要らない。分けると、
/// 未解決の多いライブラリ（＝この機能がいちばん効く場面）でパースが 2 倍になる。
public struct ParseAttempt: Sendable {
    public let result: ParseResult?
    /// **一致しなかったときだけ**入る。
    public let nearest: NearestFormat?

    public init(result: ParseResult?, nearest: NearestFormat?) {
        self.result = result
        self.nearest = nearest
    }
}

public protocol FilenameParsing: Sendable {
    /// 拡張子を除いたファイル名（またはフォルダ名）を照合する。
    /// 登録順に評価し、**最初にマッチしたもの**を採る [FF-03]。
    /// 一致しなければ「最も近いフォーマット」を併せて返す [UR2-05]。
    func attempt(_ nameWithoutExtension: String,
                 settings: LibrarySettingsSnapshot) -> ParseAttempt

    /// 全フォーマットを試し、すべての結果を返す（編集画面のプレビュー用）[FF-06][HP-05]。
    func parseAll(_ name: String, settings: LibrarySettingsSnapshot) -> [ParseResult]
}

extension FilenameParsing {
    public func parse(_ nameWithoutExtension: String,
                      settings: LibrarySettingsSnapshot) -> ParseResult? {
        attempt(nameWithoutExtension, settings: settings).result
    }

    /// どのフォーマットにも一致しなかったとき、最も惜しかったものを返す [UR2-05]。
    public func nearestFormat(_ name: String,
                              settings: LibrarySettingsSnapshot) -> NearestFormat? {
        attempt(name, settings: settings).nearest
    }
}

public struct FilenameParser: FilenameParsing, Sendable {
    public init() {}

    public func attempt(_ nameWithoutExtension: String,
                        settings: LibrarySettingsSnapshot) -> ParseAttempt {
        let input = makeInput(nameWithoutExtension, settings: settings)
        var nearest: NearestFormat?

        for format in enabledFormats(settings) {
            let outcome = FormatMatcher.match(format, input: input,
                                              volumePatterns: settings.volumeFormats)
            guard let result = outcome.result else {
                nearest = closer(nearest, than: outcome, of: format, input: input)
                continue
            }

            // `@booktype` は語彙で照合するだけ [TY-01]。**ライブラリ自身の型名との
            // 突き合わせはしない**——本の種別はファイルの属性であってライブラリの
            // 属性ではないため、切り出した値は「本の種別」フィールドのラベルとして
            // そのまま残る（束縛があれば）。
            return ParseAttempt(result: result, nearest: nil)
        }
        return ParseAttempt(result: nil, nearest: nearest)
    }

    public func parseAll(_ name: String, settings: LibrarySettingsSnapshot) -> [ParseResult] {
        let input = makeInput(name, settings: settings)
        return enabledFormats(settings).compactMap {
            FormatMatcher.match($0, input: input,
                                volumePatterns: settings.volumeFormats).result
        }
    }

    // MARK: - 内部

    /// 候補を 1 つ評価する [UR2-05]。
    ///
    /// **1 文字も進んでいないものは候補にしない。** 「先頭のリテラルすら
    /// 合わなかった」フォーマットを「最も近い」と名指しするのは案内ではなく雑音で、
    /// しかも全部が 0 なら登録順の先頭が無条件に選ばれてしまう（実測、2026-09-01）。
    ///
    /// **要素数だけを見てはいけない**［code-review の指摘］——先頭が
    /// 空マッチしうるノード（弾力的空白 [WS-01]・`@ignore`）だと、入力を
    /// 1 文字も消費しないまま要素数が 1 進む。`@ignore [@circle] @title` の
    /// ようなフォーマットが 1 本あるだけで、それが全部の未整理ファイルの
    /// 「最も近い」になってしまう。
    ///
    /// **探索を打ち切ったもの [MT2-02] も候補にしない。** 途中で止めた走査の
    /// 到達点は「どこまで筋が通ったか」を表さない。
    func closer(_ best: NearestFormat?, than outcome: MatchOutcome,
                of format: CompiledFormat, input: ParseInput) -> NearestFormat? {
        guard !outcome.exceededStepLimit,
              outcome.satisfiedNodes > 0, outcome.furthestIndex > 0 else { return best }
        let reach = input.originalRange(
            of: outcome.furthestIndex..<outcome.furthestIndex).lowerBound
        let candidate = NearestFormat(formatID: format.id,
                                      satisfiedNodes: outcome.satisfiedNodes,
                                      reachedIndex: reach)
        guard let best else { return candidate }
        // 同点は登録順で先勝ち（照合そのもの [FF-03] と同じ規則）。
        if candidate.satisfiedNodes != best.satisfiedNodes {
            return candidate.satisfiedNodes > best.satisfiedNodes ? candidate : best
        }
        return candidate.reachedIndex > best.reachedIndex ? candidate : best
    }

    func makeInput(_ name: String, settings: LibrarySettingsSnapshot) -> ParseInput {
        // マスクは**パース前**に行う [PTI-01]。
        ProtectedTokenMasker.mask(name, tokens: settings.protectedTokens)
    }

    func enabledFormats(_ settings: LibrarySettingsSnapshot) -> [CompiledFormat] {
        settings.filenameFormats.filter(\.isEnabled).sorted { $0.priority < $1.priority }
    }
}
