//
//  フォルダ名がラベルとして妥当かの実測 [RG3-24]。**純粋関数**（`QooKit`）。
//
//  登録ウィザードの「フォルダ名を解析対象にする」の**既定値**をこれで決める
//  ［ユーザー判断］。配置だけを見る（サブフォルダの中にあるか）方式では、
//  作品名やジャンルでフォルダ分けしている蔵書でも ON になってしまう
//  ——そこでフォルダ名を採ると、その値がサークル名や著者名のラベルになる。
//
//  測り方は割り当ての種類で変わる:
//
//  - `format`: フォルダ名がそのフォーマットに一致するか。一致しなければ
//    何も取らない [AL-23] ので、そもそも害が無い＝一致率がそのまま妥当性。
//  - `singleLabelGroup`: フォルダ名を**一切検査せず**ラベルにするので、
//    「そのフォルダ名が、ファイル名から取れる同じフィールドの値と一致するか」
//    で測る。一致するなら、そのフォルダはその軸で分けられている。
//
//  実蔵書での裏付け: サークル／著者で分けた蔵書では 97〜99% が一致した［実測］。
//
import Foundation

public enum FolderUsageFit {

    public struct Result: Sendable, Equatable {
        /// フォルダ名がラベルとして妥当だった件数。
        public let matched: Int
        /// 1 階層目のフォルダに入っていたサンプルの数。
        public let total: Int

        public var rate: Double { total == 0 ? 0 : Double(matched) / Double(total) }

        /// 既定を ON にしてよいか。**過半数**を境にする——実蔵書では
        /// 97〜99%、別の軸で分けていればほぼ 0% になり、中間はまれ［実測］。
        public var suggestsOn: Bool { total > 0 && rate >= 0.5 }

        public init(matched: Int, total: Int) {
            self.matched = matched
            self.total = total
        }
    }

    /// - Parameters:
    ///   - samples: 1 階層目のフォルダ名と、その中のファイル名（拡張子なし）の組。
    ///     ライブラリ直下に置かれたファイルは渡さない（測る対象が無いため）。
    ///   - settings: 1 階層目の割り当てを含む設定。
    public static func measure(samples: [(folder: String, filename: String)],
                               settings: LibrarySettingsSnapshot,
                               parser: some FilenameParsing = FilenameParser()) -> Result
    {
        guard let assignment = settings.folderLevelAssignments[1] else {
            return Result(matched: 0, total: 0)
        }

        switch assignment {
        case .none:
            return Result(matched: 0, total: 0)

        case .format(let format):
            // 一致しなければ何も取らないので、一致率がそのまま妥当性になる。
            var matched = 0
            for sample in samples {
                let input = ProtectedTokenMasker.mask(sample.folder,
                                                      tokens: settings.protectedTokens)
                if FormatMatcher.match(format, input: input,
                                       volumePatterns: settings.volumeFormats).result != nil {
                    matched += 1
                }
            }
            return Result(matched: matched, total: samples.count)

        case .singleLabelGroup(let field):
            // フォルダ名を検査しないので、ファイル名側の同じフィールドと
            // 突き合わせる。ファイル名からその値が取れないサンプルは
            // **分母から外す**——判断の材料が無いものを不一致に数えると、
            // ファイル名がラベルを持たない蔵書（フォルダ名だけが持つ、まさに
            // この機能が要る配置）で常に OFF になってしまう。
            var matched = 0
            var judged = 0
            for sample in samples {
                let attempt = parser.attempt(sample.filename, settings: settings)
                guard let parsed = attempt.result.map({
                    FieldPostProcessor.postProcess($0, settings: settings)
                }), let values = parsed.labelValues[field], !values.isEmpty else { continue }
                judged += 1
                let folder = TextNormalizer.normalize(sample.folder)
                if values.contains(where: { TextNormalizer.normalize($0) == folder }) {
                    matched += 1
                }
            }
            return Result(matched: matched, total: judged)
        }
    }
}
