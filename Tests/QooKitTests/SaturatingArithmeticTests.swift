import Foundation
import Testing

@testable import QooKit

/// アーカイブの宣言サイズ合算に使う飽和加算 [フェーズ1完了時の監査で追加]。
/// 素の `+` だと、`Int64.max` 級の宣言値を並べた細工アーカイブで合算が
/// トラップし、上限検査に到達する前にアプリごと落ちる。
@Suite struct SaturatingArithmeticTests {
    @Test func saturatesAtMaxInsteadOfTrapping() {
        #expect(Int64.max.addingClamped(Int64.max) == Int64.max)
        #expect(Int64.max.addingClamped(1) == Int64.max)
        #expect((Int64.max - 1).addingClamped(10) == Int64.max)
    }

    @Test func behavesLikePlainAdditionWithoutOverflow() {
        #expect(Int64(2).addingClamped(3) == 5)
        #expect(Int64(-2).addingClamped(3) == 1)
        #expect(Int64(0).addingClamped(0) == 0)
    }

    @Test func saturatesAtMinForNegativeOverflow() {
        #expect(Int64.min.addingClamped(-1) == Int64.min)
    }
}
