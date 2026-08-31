import Foundation
import Testing
@testable import QooKit

@Suite("メタデータの保護 [PR-01〜PR-09]")
struct MetadataProtectionTests {

    private func field(_ n: Int64) -> ProtectionScope { .field(LabelGroupID(rawValue: n)) }

    // MARK: - 綴り

    @Test("綴りは往復する")
    func storageKeyRoundTrips() {
        for scope in [ProtectionScope.basic, field(1), field(9999)] {
            #expect(ProtectionScope(storageKey: scope.storageKey) == scope)
        }
    }

    @Test("解釈できない綴りは受け付けない")
    func rejectsUnknownKeys() {
        #expect(ProtectionScope(storageKey: "") == nil)
        #expect(ProtectionScope(storageKey: "field:") == nil)
        #expect(ProtectionScope(storageKey: "field:abc") == nil)
        #expect(ProtectionScope(storageKey: "series") == nil)
    }

    /// **同じ集合は毎回同じ文字列になること。** 揃っていないと、意味の無い
    /// UPDATE と JSON バックアップの差分が出る。
    @Test("符号化は決定的（綴りの昇順）")
    func encodingIsDeterministic() {
        let a = ProtectionScopeCoding.encode([field(2), .basic, field(1)])
        let b = ProtectionScopeCoding.encode([.basic, field(1), field(2)])
        #expect(a == b)
        #expect(a == #"["basic","field:1","field:2"]"#)
    }

    @Test("空集合は既定値と同じ形")
    func emptyMatchesTheDefault() {
        #expect(ProtectionScopeCoding.encode([]) == ProtectionScopeCoding.empty)
        #expect(ProtectionScopeCoding.decode(ProtectionScopeCoding.empty).isEmpty)
    }

    @Test("符号化と復号は往復する")
    func codingRoundTrips() {
        let scopes: Set<ProtectionScope> = [.basic, field(3), field(7)]
        #expect(ProtectionScopeCoding.decode(ProtectionScopeCoding.encode(scopes)) == scopes)
    }

    /// **行ごと捨てない。** 将来スコープの種類が増えた版で書かれた行を古い版が
    /// 読んでも、分かるぶんの保護は効いたままになる（全部失うより害が小さい）。
    @Test("解釈できない要素だけを捨てる")
    func dropsOnlyTheUnknownElements() {
        let text = #"["basic","future:1","field:2"]"#
        #expect(ProtectionScopeCoding.decode(text) == [.basic, field(2)])
    }

    @Test("壊れた入力でも空集合として読む")
    func brokenInputIsEmpty() {
        #expect(ProtectionScopeCoding.decode(nil).isEmpty)
        #expect(ProtectionScopeCoding.decode("").isEmpty)
        #expect(ProtectionScopeCoding.decode("{}").isEmpty)
        #expect(ProtectionScopeCoding.decode("[1,2]").isEmpty)
    }

    // MARK: - 全体の判定 [PR-02]

    /// **フィールドは増減する**ので、集合だけを見て「全体」は判定できない。
    @Test("全体はフィールド一覧と突き合わせて判定する")
    func coversEverythingNeedsTheFieldList() {
        let fields = [LabelGroupID(rawValue: 1), LabelGroupID(rawValue: 2)]
        let all: Set<ProtectionScope> = [.basic, field(1), field(2)]
        #expect(all.coversEverything(fields: fields))
        // フィールドが 1 つ増えたら、同じ集合はもう「全体」ではない。
        #expect(!all.coversEverything(fields: fields + [LabelGroupID(rawValue: 3)]))
        // 基本情報が抜けていたら全体ではない。
        #expect(!Set([field(1), field(2)]).coversEverything(fields: fields))
    }

    @Test("全体の集合を組み立てられる")
    func everythingBuildsTheFullSet() {
        let fields = [LabelGroupID(rawValue: 1), LabelGroupID(rawValue: 2)]
        #expect(Set<ProtectionScope>.everything(fields: fields) == [.basic, field(1), field(2)])
        #expect(Set<ProtectionScope>.everything(fields: []) == [.basic])
    }

    @Test("保護されたフィールドだけを取り出せる")
    func extractsProtectedFields() {
        let scopes: Set<ProtectionScope> = [.basic, field(3), field(5)]
        #expect(scopes.protectedFields == [LabelGroupID(rawValue: 3), LabelGroupID(rawValue: 5)])
    }

    // MARK: - 旧来の印からの読み替え [PR-08]

    /// **DB の移行と JSON の取り込みが同じ規則を通る。** 片方だけ直すと、
    /// 以前書き出した文書と移行済みの DB とで結果が食い違う。
    @Test("旧来の印を保護へ読み替える")
    func legacyMarksBecomeProtection() {
        #expect(LegacyMetadataProtection.basicIsProtected(titleOrigin: "manual"))
        #expect(!LegacyMetadataProtection.basicIsProtected(titleOrigin: "auto"))
        #expect(!LegacyMetadataProtection.basicIsProtected(titleOrigin: nil))

        #expect(LegacyMetadataProtection.fieldIsProtected(labelOrigin: "manual"))
        // **`manuallyRemoved` も保護になる**——行を消すだけでは、次の走査で
        // 外したはずのラベルが復活する。
        #expect(LegacyMetadataProtection.fieldIsProtected(labelOrigin: "manuallyRemoved"))
        #expect(!LegacyMetadataProtection.fieldIsProtected(labelOrigin: "auto"))
        #expect(!LegacyMetadataProtection.fieldIsProtected(labelOrigin: nil))

        #expect(!LegacyMetadataProtection.isAttached(labelOrigin: "manuallyRemoved"))
        #expect(LegacyMetadataProtection.isAttached(labelOrigin: "manual"))
        #expect(LegacyMetadataProtection.isAttached(labelOrigin: nil), "版 3 以降は印を持たない")
    }
}
