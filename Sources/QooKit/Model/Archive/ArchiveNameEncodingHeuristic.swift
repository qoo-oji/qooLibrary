import Foundation

/// zip / 7z の UTF-8 フラグ未設定時のエンコーディング推定 [AR-02][9.2 節]。
/// RAR はアーカイブ側がエンコーディング情報を持つため対象外 [AR-03]。
///
/// このバージョンは判定ロジックのみを実装する。展開前プレビュー UI
/// （先頭 20 エントリを両エンコーディングで並べて表示 [EN-02]、ユーザーが
/// 手動で変更できる導線 [EN-01][EN-04]）と、実際のバックエンドへの統合
/// （libarchive から生バイト列のパス名を取り出す設定）は 1-7 の次段階で行う。
public enum ArchiveNameEncodingHeuristic {
    public struct Candidate: Sendable, Equatable {
        public let encoding: String.Encoding
        public let score: Double
        public let decodedSamples: [String]
    }

    private static let sampleLimit = 20
    private static let mojibakePenalty = 0.5
    private static let japaneseBonus = 0.3

    /// 生のバイト列（デコード前のパス名）から候補をスコア降順で返す。
    /// 空配列を渡した場合は UTF-8 を既定候補として返す。
    public static func evaluate(rawNames: [Data]) -> [Candidate] {
        guard !rawNames.isEmpty else {
            return [
                Candidate(encoding: .utf8, score: 1, decodedSamples: []),
                Candidate(encoding: .shiftJIS, score: 0, decodedSamples: []),
            ]
        }

        let utf8 = score(rawNames: rawNames, encoding: .utf8)
        let cp932 = score(rawNames: rawNames, encoding: .shiftJIS)
        return [utf8, cp932].sorted { $0.score > $1.score }
    }

    private static func score(rawNames: [Data], encoding: String.Encoding) -> Candidate {
        var decodedCount = 0
        var penaltyHits = 0
        var japaneseHits = 0
        var samples: [String] = []

        for raw in rawNames {
            guard let decoded = String(data: raw, encoding: encoding), !decoded.isEmpty else { continue }
            decodedCount += 1
            if samples.count < sampleLimit { samples.append(decoded) }

            if containsSuspiciousCharacters(decoded) { penaltyHits += 1 }
            if containsJapaneseCharacterClass(decoded) { japaneseHits += 1 }
        }

        let total = Double(rawNames.count)
        let decodeRate = Double(decodedCount) / total
        let penaltyRate = Double(penaltyHits) / total
        let japaneseRate = Double(japaneseHits) / total

        var value = decodeRate - penaltyRate * mojibakePenalty
        if encoding == .shiftJIS {
            value += japaneseRate * japaneseBonus
        }
        value = min(1, max(0, value))

        return Candidate(encoding: encoding, score: value, decodedSamples: samples)
    }

    /// U+FFFD（デコード失敗の置換文字）、制御文字、よくある化けパターン
    /// （"?" の連続など）の出現を減点対象とする。
    private static func containsSuspiciousCharacters(_ string: String) -> Bool {
        if string.contains("\u{FFFD}") { return true }
        if string.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\t" }) {
            return true
        }
        if string.range(of: "\\?{3,}", options: .regularExpression) != nil { return true }
        return false
    }

    private static func containsJapaneseCharacterClass(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) // ひらがな
                || (0x30A0...0x30FF).contains(scalar.value) // カタカナ
                || (0x4E00...0x9FFF).contains(scalar.value) // CJK統合漢字
        }
    }
}
