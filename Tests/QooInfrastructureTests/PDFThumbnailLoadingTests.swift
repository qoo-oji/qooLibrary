import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct PDFThumbnailLoadingTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-pdf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `CoreGraphics` の PDF コンテキスト API だけで、実際に開ける最小限の
    /// 1ページ PDF をその場で組み立てる（バイナリのテストフィクスチャを
    /// リポジトリに含めずに済む、`TestImageFixture` と同じ方針）。ページ全面に
    /// 画像を1枚描画する（`context.draw` は PDF 書き出し時に Image XObject +
    /// `Do` 演算子として記録される、実際のスキャン PDF と同じ構造——ごく小さい
    /// 画像だと CoreGraphics がインライン画像 `BI`/`ID`/`EI` 形式で書き出し
    /// XObject を経由しないことがあるため、ページ寸法に合わせた十分な大きさに
    /// している）。
    private func makeImageBasedPDF(at url: URL, width: CGFloat, height: CGFloat) {
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("PDF コンテキストの作成に失敗した")
            return
        }
        context.beginPDFPage(nil)
        let image = TestImageFixture.makeCGImage(width: Int(width), height: Int(height), red: 1, green: 0, blue: 0)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    /// 画像を一切描画せず、塗りつぶしだけのページ（ベクター描画のみ、
    /// テキストも画像も無い）。
    private func makeBlankPDF(at url: URL, width: CGFloat, height: CGFloat) {
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("PDF コンテキストの作成に失敗した")
            return
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
    }

    /// CoreText でページに実際のテキストを描画する（`Tj`/`TJ` 演算子として
    /// 記録される、通常のテキスト主体ドキュメントと同じ構造）。
    private func makeTextBasedPDF(at url: URL, width: CGFloat, height: CGFloat) {
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("PDF コンテキストの作成に失敗した")
            return
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello, world", attributes: attributes))
        context.textPosition = CGPoint(x: 20, y: height / 2)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    /// [ユーザー指摘・要望: 「画像ベースではない、通常のドキュメントの場合は
    /// サムネイル表示の対象外にする処理ということでいいですか？」「画像ベース
    /// かどうかで揃えてください」] 画像ベースのページのみサムネイルの対象に
    /// なることを、画像・テキストのみ・どちらでもない（ベクター塗りつぶし
    /// のみ）の3パターンで検証する。
    @Test func makeThumbnailRendersFirstPageWhenPageIsImageBased() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("book.pdf")
        makeImageBasedPDF(at: pdfURL, width: 400, height: 200) // 2:1 の横長

        let loader = CoreGraphicsPDFThumbnailLoader()
        let thumbnail = await loader.makeThumbnail(for: pdfURL, maxPixelSize: 100)

        let image = try #require(thumbnail)
        #expect(image.width == 100)
        #expect(image.height == 50)
    }

    @Test func makeThumbnailReturnsNilWhenPageHasText() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("document.pdf")
        makeTextBasedPDF(at: pdfURL, width: 400, height: 200)

        let loader = CoreGraphicsPDFThumbnailLoader()
        let thumbnail = await loader.makeThumbnail(for: pdfURL, maxPixelSize: 100)

        #expect(thumbnail == nil)
    }

    @Test func makeThumbnailReturnsNilWhenPageHasNeitherTextNorImage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("blank.pdf")
        makeBlankPDF(at: pdfURL, width: 400, height: 200)

        let loader = CoreGraphicsPDFThumbnailLoader()
        let thumbnail = await loader.makeThumbnail(for: pdfURL, maxPixelSize: 100)

        #expect(thumbnail == nil)
    }

    @Test func makeThumbnailReturnsNilForNonPDFFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAPDF = root.appendingPathComponent("notes.txt")
        try Data("plain text, not a PDF".utf8).write(to: notAPDF)

        let loader = CoreGraphicsPDFThumbnailLoader()
        let thumbnail = await loader.makeThumbnail(for: notAPDF, maxPixelSize: 100)

        #expect(thumbnail == nil)
    }
}

/// **mmap を経由しない開き方** [F3、8章 §8.11.16]。
///
/// `CGPDFDocument(url:)` は後備ファイルを mmap するため、**ネットワーク上の
/// PDF では切断中のページフォルトが `SIGBUS` になり、プロセスごと死ぬ**
/// （遮断計測で確定）。ネットワークのときだけ読み切ってから開く経路へ
/// 切り替えるので、その経路が**同じ結果を返すこと**を固定する。
///
/// 切り替えの判断自体（`MountTable.isRemote`）は `MountTableTests` の担当。
/// ここでは「読み切って開いても壊れない」ことだけを見る。
@Suite struct PDFInMemoryOpenTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-pdf-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ページ全面に実画像を描いた 1 ページの PDF。**小さすぎるとインライン
    /// 画像として書き出され XObject にならない**ので、ページ相当の大きさにする
    /// （既存のテストが同じ理由でそうしている）。
    private func makeImageBasedPDF(at url: URL, width: CGFloat, height: CGFloat) {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let image = TestImageFixture.makeCGImage(width: Int(width), height: Int(height))
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    @Test func openingInMemoryYieldsTheSameDocumentAsMapping() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("cover.pdf")
        makeImageBasedPDF(at: pdf, width: 300, height: 400)

        let mapped = try #require(CGPDFDocument(pdf as CFURL), "前提: mmap 経由では開ける")
        let inMemory = try #require(
            CoreGraphicsPDFThumbnailLoader.openInMemory(pdf),
            "読み切ってから開く経路で開けていない（ネットワーク上の PDF が全滅する）"
        )
        #expect(inMemory.numberOfPages == mapped.numberOfPages)

        let mappedBox = try #require(mapped.page(at: 1)).getBoxRect(.mediaBox)
        let memoryBox = try #require(inMemory.page(at: 1)).getBoxRect(.mediaBox)
        #expect(memoryBox == mappedBox, "同じページなのに mediaBox が違う")
    }

    /// PDF でないものを渡しても落ちない。
    @Test func openingInMemoryReturnsNilForNonPDF() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notPDF = dir.appendingPathComponent("cover.pdf")
        try Data("これは PDF ではない".utf8).write(to: notPDF)
        #expect(CoreGraphicsPDFThumbnailLoader.openInMemory(notPDF) == nil)
    }

    /// 存在しないファイルでも落ちない。
    @Test func openingInMemoryReturnsNilForMissingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CoreGraphicsPDFThumbnailLoader.openInMemory(dir.appendingPathComponent("no.pdf")) == nil)
    }
}
