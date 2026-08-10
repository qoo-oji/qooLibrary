import Foundation
import Testing

@testable import QooKit

@Suite struct ArchiveNameEncodingHeuristicTests {
    private func utf8Data(_ names: [String]) -> [Data] {
        names.map { Data($0.utf8) }
    }

    private func shiftJISData(_ names: [String]) -> [Data] {
        names.compactMap { $0.data(using: .shiftJIS) }
    }

    @Test func emptyInputDefaultsToUTF8() {
        let candidates = ArchiveNameEncodingHeuristic.evaluate(rawNames: [])
        #expect(candidates.first?.encoding == .utf8)
    }

    @Test func utf8EncodedJapaneseNamesScoreUTF8Highest() {
        let names = ["第1巻 サンプル漫画.jpg", "表紙.png", "本文/ページ001.jpg"]
        let candidates = ArchiveNameEncodingHeuristic.evaluate(rawNames: utf8Data(names))
        #expect(candidates.first?.encoding == .utf8)
    }

    @Test func shiftJISEncodedJapaneseNamesScoreShiftJISHighest() {
        let names = ["第1巻 サンプル漫画.jpg", "表紙.png", "本文/ページ001.jpg"]
        let rawNames = shiftJISData(names)
        #expect(rawNames.count == names.count) // エンコード自体が成功していることを前提にする

        let candidates = ArchiveNameEncodingHeuristic.evaluate(rawNames: rawNames)
        #expect(candidates.first?.encoding == .shiftJIS)
    }

    @Test func plainASCIINamesDoNotCrashAndDecodeUnderBothEncodings() {
        let names = ["cover.jpg", "page001.jpg", "page002.jpg"]
        let candidates = ArchiveNameEncodingHeuristic.evaluate(rawNames: utf8Data(names))
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.score >= 0 && $0.score <= 1 })
    }

    @Test func decodedSamplesAreCapped() {
        let names = (1...30).map { "page\($0).jpg" }
        let candidates = ArchiveNameEncodingHeuristic.evaluate(rawNames: utf8Data(names))
        for candidate in candidates {
            #expect(candidate.decodedSamples.count <= 20)
        }
    }
}
