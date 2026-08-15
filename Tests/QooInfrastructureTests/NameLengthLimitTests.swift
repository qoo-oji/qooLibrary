import Foundation
import QooKit
import Testing

@testable import QooInfrastructure

/// **名前の長さの上限は、書き込み先によって数え方が違う** [ER-03]。
///
/// ## 実測（このマシンで確認した値）
///
/// | 形式 | `あ` の最大個数 | `が`(NFC) の最大個数 | 実質の単位 |
/// |---|---|---|---|
/// | APFS / HFS+ | 255 | 127 | NFD 後の UTF-16 単位 255 |
/// | exFAT / FAT | 255 | 165 | （駆動側の正規化に依存）|
/// | **SMB（実 NAS）** | **85** | **85** | **UTF-8 バイト 255** |
/// | UDF | 78 | 39 | さらに短い |
///
/// `pathconf(_PC_NAME_MAX)` はどれも 255（UDF は 254）を返すため、
/// **単位は問い合わせられない**。だから実測した形式についてだけ規則を持ち、
/// 知らない形式では検査しない。
///
/// ネットワークボリュームは常時つながっているとは限らないので、この suite は
/// **実際の SMB マウントに一切依存しない**（規則そのものを検証する）。
@Suite struct NameLengthLimitTests {
    private let japanese100 = String(repeating: "あ", count: 100) // 300 バイト / 100 単位

    /// バイト単位の規則は、日本語の長い名前を正しく弾くこと。
    /// これがこの機能の存在理由（Mac 内では作れるのに書き込み先では作れない）。
    @Test func byteRuleRejectsLongJapaneseNames() {
        let rule = NameLengthLimit.Rule(unit: .bytes, maximum: 255)
        #expect(japanese100.utf8.count == 300)
        #expect(!rule.accepts(japanese100))
        // 85 文字 = 255 バイトちょうどは通る（実測の境界）。
        #expect(rule.accepts(String(repeating: "あ", count: 85)))
        #expect(!rule.accepts(String(repeating: "あ", count: 86)))
    }

    /// 単位ベースの規則は同じ名前を通すこと。**ここが食い違う**からこそ、
    /// 書き込み先ごとに見る必要がある。
    @Test func unitRuleAcceptsTheSameName() {
        let rule = NameLengthLimit.Rule(unit: .decomposedUTF16, maximum: 255)
        #expect(rule.accepts(japanese100), "Mac 内で作れる名前を弾いてはいけない")
        // 濁点は NFD で 2 単位になる（実測: APFS は「が」127 個が上限）。
        #expect(rule.accepts(String(repeating: "が", count: 127)))
        #expect(!rule.accepts(String(repeating: "が", count: 128)))
    }

    /// ローカルの形式では規則を持たない（入口の検査で足りるため重ねない）。
    /// ここが変わると、ローカルへのコピーで余計な検査が走る。
    @Test func localVolumesGetNoExtraRule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-namelimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NameLengthLimit.rule(forVolumeAt: root) == nil)
    }

    /// 書き込み先がまだ無くても、実在する祖先まで遡って判断できること
    /// （展開先フォルダをこれから作る場合など）。
    @Test func resolvesThroughAMissingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-namelimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 落ちずに答えが返ること（ローカルなので `nil`）。
        #expect(NameLengthLimit.rule(forVolumeAt: root.appendingPathComponent("not/created/yet")) == nil)
    }

    /// 文言 [ER-03]。**なぜ Mac 内では使えるのに弾かれるのか**が伝わること。
    @Test func theMessageExplainsWhyALocallyValidNameIsRejected() {
        let error = FileOperationError.nameTooLongForDestination(
            name: japanese100, item: URL(fileURLWithPath: "/tmp/\(japanese100)"),
            length: 300, limit: 255, unitIsBytes: true
        )
        let message = error.localizedDescription
        #expect(!message.contains("FileOperationError"))
        #expect(message.contains("300"))
        #expect(message.contains("255"))
        // バイトで数えることと、日本語が 1 文字 3 バイトであることを示す。
        #expect(message.contains("バイト"))
        #expect(message.contains("3 バイト"))
    }
}
