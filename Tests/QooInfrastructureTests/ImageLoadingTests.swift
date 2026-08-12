import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct ImageLoadingTests {
    @Test func imageSizeReadsHeaderDimensions() {
        let data = TestImageFixture.makePNGData(width: 40, height: 30)
        let loader = DefaultImageLoader()
        let size = loader.imageSize(from: data)
        #expect(size?.width == 40)
        #expect(size?.height == 30)
    }

    @Test func imageSizeReturnsNilForGarbageData() {
        let loader = DefaultImageLoader()
        #expect(loader.imageSize(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test func makeThumbnailProducesDownsizedImageKeepingAspectRatio() throws {
        let data = TestImageFixture.makePNGData(width: 400, height: 200)
        let loader = DefaultImageLoader()
        let thumbnail = try loader.makeThumbnail(from: data, maxPixelSize: 100)
        #expect(thumbnail.width == 100)
        #expect(thumbnail.height == 50)
    }

    @Test func makeThumbnailThrowsForGarbageData() {
        let loader = DefaultImageLoader()
        #expect(throws: ImageLoadingError.self) {
            try loader.makeThumbnail(from: Data([0x00, 0x01]), maxPixelSize: 100)
        }
    }

    @Test func makeThumbnailThrowsWhenPixelCountExceedsLimit() {
        // [IM-01] 実際に1億画素の画像を作らずに上限超過パスを検証するため、
        // 上限を注入できるようにしてある。
        let data = TestImageFixture.makePNGData(width: 100, height: 100) // 10,000 px
        let loader = DefaultImageLoader(maxPixelCount: 5_000)
        #expect(throws: ImageLoadingError.pixelCountExceedsLimit) {
            try loader.makeThumbnail(from: data, maxPixelSize: 50)
        }
    }
}
