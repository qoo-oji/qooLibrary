import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import QooApplication
@testable import QooInfrastructure
import QooKit
@testable import QooPersistence

//
//  カバー画像の通し [CV-01〜CV-08][IV-02②][IV-03][DS-06]。
//
//  **モデルの状態を見るだけでは足りない。** `CoverEditorModel` が
//  `.userSpecified` を返しても、実際に画面へ出る絵が変わっていなければ
//  「差し替えた」ことにならない——ここは実アーカイブ・実 DB・実
//  `ThumbnailService` を通し、**最後に画素の色まで**確かめる。
//
//  ページを色で作り分けてあるのが要点: 1 ページ目=赤 / 2 ページ目=緑 /
//  サイドカー=青。どの段が効いているかが色 1 つで分かる。
//

@MainActor
@Suite("カバー画像の通し [CV-01〜CV-08][IV-03]", .serialized)
struct CoverPipelineIntegrationTests {

    // MARK: - 画像の道具

    /// 単色 PNG。
    static func solidPNG(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                         type: UTType = .png, size: Int = 64) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// 1×1 へ縮めて読む。単色画像なら縮小しても色は変わらないので、
    /// 「どのページが出ているか」をこれ 1 つで判定できる。
    static func color(of image: CGImage) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func isNear(_ actual: (r: Int, g: Int, b: Int),
                       _ expected: (r: Int, g: Int, b: Int), tolerance: Int = 12) -> Bool {
        abs(actual.r - expected.r) <= tolerance
            && abs(actual.g - expected.g) <= tolerance
            && abs(actual.b - expected.b) <= tolerance
    }

    static let red = (r: 255, g: 0, b: 0)
    static let green = (r: 0, g: 255, b: 0)
    static let blue = (r: 0, g: 0, b: 255)

    // MARK: - 作業領域

    @MainActor
    final class Workspace {
        let services: LibraryServices
        let base: URL
        let libraryRoot: URL
        let registrationUUID = UUID()
        /// **共有インスタンスを使わない**——`DefaultCoverImageCache.shared` は
        /// 開発機の実 App Support を指す。
        let thumbnails: ThumbnailService

        init(thumbnailsHidden: Bool = false) throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("qoo-cover-e2e-\(UUID().uuidString)")
            libraryRoot = base.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: libraryRoot,
                                                    withIntermediateDirectories: true)
            services = LibraryServices(userCoverStore: DefaultUserCoverStore(
                baseDirectory: base.appendingPathComponent("usercovers")))
            thumbnails = ThumbnailService(
                maxConcurrent: 2,
                cache: DefaultCoverImageCache(baseDirectory: base.appendingPathComponent("covers")),
                isGloballyHidden: { thumbnailsHidden })
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        var storeURL: URL { base.appendingPathComponent("store/qooLibrary.sqlite") }

        /// 赤・緑・黄の 3 ページを持つ本を作る。
        func makeBook(_ filename: String) async throws -> URL {
            let pages = base.appendingPathComponent("pages", isDirectory: true)
            try? FileManager.default.removeItem(at: pages)
            try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
            try CoverPipelineIntegrationTests.solidPNG(1, 0, 0)
                .write(to: pages.appendingPathComponent("001.png"))
            try CoverPipelineIntegrationTests.solidPNG(0, 1, 0)
                .write(to: pages.appendingPathComponent("002.png"))
            try CoverPipelineIntegrationTests.solidPNG(1, 1, 0)
                .write(to: pages.appendingPathComponent("003.png"))
            let book = libraryRoot.appendingPathComponent(filename)
            try await LibarchiveBackend.shared.compress([pages], to: book,
                                                        options: .default)
            try FileManager.default.removeItem(at: pages)
            return book
        }

        func makeSidecar(for book: URL, _ data: Data, extension ext: String = "png") throws {
            let covers = libraryRoot.appendingPathComponent("covers", isDirectory: true)
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            let name = book.deletingPathExtension().lastPathComponent
            try data.write(to: covers.appendingPathComponent("\(name).\(ext)"))
        }

        func start() async throws -> LibrarySummary {
            await services.bootstrap(storeURL: storeURL)
            let template = try #require(
                services.presetTemplates.first { $0.key == "builtin.general-comic-a" })
            let id = try await services.enable(
                registrationUUID: registrationUUID, displayName: "カバー通し",
                url: libraryRoot, bookmarkData: Data(), template: template)
            _ = try await services.scan(libraryID: id, root: libraryRoot)
            return try #require(services.library(registrationUUID: registrationUUID))
        }

        /// 画面へ出る絵。**モデルが指した URL をそのまま `ThumbnailService` へ
        /// 渡す**——View と同じ経路を通す。
        func displayedColor(_ subject: CoverEditorModel.Subject) async -> (r: Int, g: Int, b: Int)? {
            guard let image = await thumbnails.thumbnail(for: subject.previewURL,
                                                         maxPixelSize: 128) else { return nil }
            return CoverPipelineIntegrationTests.color(of: image)
        }
    }

    private func subject(_ model: CoverEditorModel) throws -> CoverEditorModel.Subject {
        guard case .ready(let subject) = model.state else {
            Issue.record("ready ではない: \(model.state)")
            throw CancellationError()
        }
        return subject
    }

    // MARK: - 通し

    /// **この 1 本がこの機能の芯。** 差し替えたら画面へ出る絵が実際に変わり、
    /// 戻したら元へ戻る——状態だけを見ていては確かめられない。
    @Test("差し替えると表示される絵が変わり、既定に戻すと戻る [CV-02][CV-05][CV-07]")
    func replacingChangesWhatIsDisplayed() async throws {
        let w = try Workspace()
        let book = try await w.makeBook("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let library = try await w.start()

        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: book, library: library, services: w.services)

        // ③ 自動抽出 = 1 ページ目（赤）
        var current = try subject(model)
        #expect(current.resolvedSource == .auto)
        var color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.red), "自動抽出は 1 ページ目のはず: \(color)")

        // ① 2 ページ目（緑）へ差し替える [CV-05]
        let picker = ArchiveCoverPicker(url: book)
        let pages = await picker.candidates()
        #expect(pages.count == 3)
        let secondPage = try #require(await picker.data(for: pages[1]))
        try await model.replace(withImageData: secondPage)

        current = try subject(model)
        #expect(current.resolvedSource == .userSpecified)
        color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.green), "差し替えたページが出ていない: \(color)")

        // [CV-07] 既定に戻すと自動抽出（赤）へ
        try await model.revert()
        current = try subject(model)
        #expect(current.resolvedSource == .auto)
        color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.red), "既定へ戻っていない: \(color)")
    }

    /// **解決順序を色で確かめる** [IV-03]。①ユーザー指定 > ②サイドカー > ③先頭画像。
    @Test("ユーザー指定 > サイドカー > 先頭画像 の順で出る [IV-03][IV-02②]")
    func resolutionOrderIsVisible() async throws {
        let w = try Workspace()
        let book = try await w.makeBook("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        try w.makeSidecar(for: book, Self.solidPNG(0, 0, 1))       // 青
        let library = try await w.start()

        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: book, library: library, services: w.services)

        // ② サイドカー（青）が先頭画像（赤）に勝つ
        var current = try subject(model)
        #expect(current.resolvedSource == .sidecar)
        var color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.blue), "サイドカーが出ていない: \(color)")

        // ① ユーザー指定（緑）がサイドカーに勝つ
        let picker = ArchiveCoverPicker(url: book)
        let pages = await picker.candidates()
        try await model.replace(withImageData: try #require(await picker.data(for: pages[1])))
        current = try subject(model)
        #expect(current.resolvedSource == .userSpecified)
        color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.green), "ユーザー指定が出ていない: \(color)")

        // 既定へ戻すと**サイドカーへ落ちる**（先頭画像ではない）
        try await model.revert()
        current = try subject(model)
        #expect(current.resolvedSource == .sidecar)
        color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.blue), "戻した先がサイドカーになっていない: \(color)")
    }

    /// [CV-08] 複製は元画像から独立している。**元を消しても表示は維持される。**
    @Test("元画像を消してもカバーは出続ける [CV-08]")
    func coverSurvivesTheSourceImage() async throws {
        let w = try Workspace()
        let book = try await w.makeBook("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let library = try await w.start()

        // アーカイブの外にある画像を選ぶ [CV-05 の後半]
        let external = w.base.appendingPathComponent("外部の絵.png")
        try Self.solidPNG(0, 0, 1).write(to: external)
        let data = try #require(await CoverImageSourceResolver.firstImageData(for: external))

        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: book, library: library, services: w.services)
        try await model.replace(withImageData: data)
        try FileManager.default.removeItem(at: external)

        await model.load(url: book, library: library, services: w.services)
        let current = try subject(model)
        #expect(current.resolvedSource == .userSpecified)
        let color = try #require(await w.displayedColor(current))
        #expect(Self.isNear(color, Self.blue), "元を消したら出なくなった: \(color)")
    }

    /// [DS-06] サムネイル非表示のときはカバーも作らない・出さない。
    @Test("サムネイル非表示ではカバーも作らない [DS-06][DS-05]")
    func hiddenThumbnailsSuppressTheCover() async throws {
        let w = try Workspace(thumbnailsHidden: true)
        let book = try await w.makeBook("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let library = try await w.start()

        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: book, library: library, services: w.services)
        let picker = ArchiveCoverPicker(url: book)
        let pages = await picker.candidates()
        try await model.replace(withImageData: try #require(await picker.data(for: pages[1])))

        let current = try subject(model)
        #expect(current.resolvedSource == .userSpecified, "指定そのものは残る")
        #expect(await w.displayedColor(current) == nil, "非表示中は生成しない")
    }

    /// **元の形式を保つ** [TH-04]。PNG へ焼き直すと JPEG が肥大し、
    /// アニメーション GIF は 1 コマになる。
    @Test("複製は元の形式のまま保つ [TH-04]")
    func copyKeepsTheOriginalFormat() async throws {
        let w = try Workspace()
        let book = try await w.makeBook("(一般コミック) [著者値A] 作品名A 第01巻.cbz")
        let library = try await w.start()

        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: book, library: library, services: w.services)
        try await model.replace(withImageData: Self.solidPNG(0, 0, 1, type: .jpeg))

        let ref = try #require(try await w.services.fileRow(at: book, in: library)?.coverImageRef)
        #expect(ref.hasSuffix(".jpeg") || ref.hasSuffix(".jpg"), "実際の拡張子: \(ref)")
    }
}
