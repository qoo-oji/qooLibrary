import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// テスト用の実画像データを `CoreGraphics`/`ImageIO` だけで組み立てる
/// （バイナリのテストフィクスチャをリポジトリに含めずに済む）。
enum TestImageFixture {
    static func makePNGData(width: Int, height: Int, red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
