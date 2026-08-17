import CoreGraphics
import Foundation
import Testing

@testable import QooInfrastructure

/// `CompositeVideoThumbnailLoader` の順序と打ち切りの検証。
///
/// 実際の生成経路（`QLThumbnailGenerator`・VideoToolbox）は、結果が
/// インストール済み拡張と実メディアに依存するため自動テストの対象外
/// （`QLVideoThumbnailLoader` 自体に単体テストが無いのと同じ方針）。
/// ここで固定するのは**合成の規則**だけである。
struct CompositeVideoThumbnailLoaderTests {
    /// 呼ばれた回数を数え、あらかじめ決めた結果を返すローダー。
    private final class SpyLoader: VideoThumbnailLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var callCountStorage = 0
        private let result: CGImage?

        init(returns result: CGImage?) {
            self.result = result
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCountStorage
        }

        func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
            recordCall()
            return result
        }

        /// **同期メソッドに切り出してある。** `NSLock.lock()` は `noasync` で、
        /// async 関数の本体から直接は呼べない。
        private func recordCall() {
            lock.lock()
            callCountStorage += 1
            lock.unlock()
        }
    }

    private static func makeImage() -> CGImage {
        TestImageFixture.makeCGImage(width: 4, height: 4)
    }

    private let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.mp4")

    @Test func stopsAtTheFirstLoaderThatSucceeds() async {
        let first = SpyLoader(returns: Self.makeImage())
        let second = SpyLoader(returns: Self.makeImage())
        let composite = CompositeVideoThumbnailLoader(loaders: [first, second])

        let image = await composite.makeThumbnail(for: url, maxPixelSize: 64)

        #expect(image != nil)
        #expect(first.callCount == 1)
        // **2 つ目は呼ばれない** — QuickLook が作れたものを再タグ付けの経路で
        // 作り直させないこと自体が、この型の存在理由。
        #expect(second.callCount == 0)
    }

    @Test func fallsThroughToTheNextLoaderWhenTheFirstReturnsNil() async {
        let first = SpyLoader(returns: nil)
        let second = SpyLoader(returns: Self.makeImage())
        let composite = CompositeVideoThumbnailLoader(loaders: [first, second])

        let image = await composite.makeThumbnail(for: url, maxPixelSize: 64)

        #expect(image != nil)
        #expect(first.callCount == 1)
        #expect(second.callCount == 1)
    }

    @Test func returnsNilWhenEveryLoaderFails() async {
        let first = SpyLoader(returns: nil)
        let second = SpyLoader(returns: nil)
        let composite = CompositeVideoThumbnailLoader(loaders: [first, second])

        let image = await composite.makeThumbnail(for: url, maxPixelSize: 64)

        #expect(image == nil)
        #expect(first.callCount == 1)
        #expect(second.callCount == 1)
    }

    /// 取り消されていたら 1 つも呼ばない（画面外へ出たセルの要求が、
    /// フォールバックのぶんだけ余分に走らないこと）。
    @Test func doesNotStartWhenAlreadyCancelled() async {
        let first = SpyLoader(returns: Self.makeImage())
        let composite = CompositeVideoThumbnailLoader(loaders: [first])
        let target = url

        let task = Task {
            // 走り出す前に取り消されている状態を作る。
            while !Task.isCancelled { await Task.yield() }
            return await composite.makeThumbnail(for: target, maxPixelSize: 64)
        }
        task.cancel()
        let image = await task.value

        #expect(image == nil)
        #expect(first.callCount == 0)
    }

    @Test func defaultOrderTriesQuickLookBeforeRetagging() {
        // 既定の並びが「QuickLook → 再タグ付け」であることを型で確かめる。
        // 順序が逆になると、QuickLook が正しく作れるものまで最小限の代替経路が
        // 先に処理してしまう。
        let loaders = CompositeVideoThumbnailLoader().loaders
        #expect(loaders.count == 2)
        #expect(loaders.first is QLVideoThumbnailLoader)
        #expect(loaders.last is RetaggedHEVCThumbnailLoader)
    }
}
