import CoreGraphics
import Foundation

/// PDF ファイルのサムネイル生成 [ユーザー要望: qooLibrary は qooViewer の
/// フロントエンドとして設計されており、qooViewer が対応するファイル形式
/// （PDF・EPUB）は qooLibrary 側でも網羅する必要がある]。
///
/// `CGPDFDocument`/`CGPDFPage` で1ページ目を直接レンダリングする。姉妹
/// プロジェクト qooViewer の `Services/PageLoader.swift`
/// `renderPDFPage(pdfURL:pageIndex:maxPixelSize:)` と同じアルゴリズム
/// （mediaBox に合わせたアスペクト比維持のスケーリング、白背景での塗り
/// つぶし、mediaBox の原点オフセット補正）を1ページ分のサムネイル生成用に
/// 移植したもの。動画（`VideoThumbnailLoading`）と異なりサードパーティの
/// QuickLook 拡張には一切依存せず、macOS 標準の CoreGraphics だけで完結する。
///
/// **画像ベースのページのみをサムネイル対象にする**［ユーザー指摘・要望:
/// 「画像ベースではない、通常のドキュメントの場合はサムネイル表示の対象外
/// にする処理ということでいいですか？」「画像ベースかどうかで揃えてください」
/// ——EPUB（`EpubCoverResolver`）は仕組み上、常に実際の画像データが見つかった
/// 場合しか値を返さない（テキストから合成したサムネイルは決して作らない）。
/// PDF 側は当初この判定が無く、テキスト主体の通常ドキュメントでも1ページ目を
/// そのまま描画していた（レンダリング結果自体は画像だが、元がテキストの
/// レイアウトを描画しただけという点で EPUB 側の基準と揃っていなかった）ため、
/// 揃えるために追加した］。ページのコンテンツストリームを `CGPDFScanner` で
/// 走査し、テキスト描画命令（`Tj`/`TJ`/`'`/`"`）が1つも無く、かつ
/// Image XObject の描画（`Do`）が1つ以上あるページだけを「画像ベース」と
/// 判定する。**既知の限界**: OCR 済みスキャン（見えない文字レイヤーを持つ
/// 画像ページ）はテキスト命令を検出するため対象外になる、Form XObject 内部
/// への再帰は行わない（多くの単純なスキャン PDF は Image XObject を直接
/// 描画するため実用上は十分だが、Form XObject 経由で画像を描画する PDF は
/// 判定できない）。
public protocol PDFThumbnailLoading: Sendable {
    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}

public struct CoreGraphicsPDFThumbnailLoader: PDFThumbnailLoading {
    public init() {}

    public func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        // **`Task.detached` では駄目** [NV6-01]。`CGPDFDocument(url:)` は
        // ファイルを実際に読むので、ネットワーク上の PDF ではここでブロックする。
        // detached も協調プールを使うため、逃げ場にならない。
        await FileIO.perform {
            Self.renderFirstPage(of: url, maxPixelSize: maxPixelSize)
        }
    }

    private static func renderFirstPage(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        guard isImageBasedPage(page) else { return nil }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let maxSize = CGFloat(maxPixelSize)
        let scale = min(maxSize / mediaBox.width, maxSize / mediaBox.height)
        let pixelWidth = max(1, Int((mediaBox.width * scale).rounded()))
        let pixelHeight = max(1, Int((mediaBox.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        context.scaleBy(x: scale, y: scale)
        // mediaBox の原点が (0, 0) でない場合に備えて平行移動しておく
        // [qooViewer の renderPDFPage と同じ対処]。
        context.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
        context.drawPDFPage(page)

        return context.makeImage()
    }

    /// ページのコンテンツストリームを走査し、テキスト描画命令が無く、かつ
    /// Image XObject の描画が1つ以上あるかを調べる。
    private static func isImageBasedPage(_ page: CGPDFPage) -> Bool {
        let contentStream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(contentStream) }
        guard let operatorTable = CGPDFOperatorTableCreate() else { return false }
        defer { CGPDFOperatorTableRelease(operatorTable) }

        for textOperator in ["Tj", "TJ", "'", "\""] {
            textOperator.withCString { CGPDFOperatorTableSetCallback(operatorTable, $0, pdfTextOperatorCallback) }
        }
        "Do".withCString { CGPDFOperatorTableSetCallback(operatorTable, $0, pdfDoOperatorCallback) }

        let state = PDFPageContentClassificationState()
        let scanner = CGPDFScannerCreate(contentStream, operatorTable, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        _ = CGPDFScannerScan(scanner)

        return state.hasImageDraw && !state.hasTextOperator
    }
}

/// `isImageBasedPage` のスキャン中に `CGPDFScanner` のコールバックから
/// 更新する可変状態。`CGPDFOperatorCallback`（`@convention(c)`、状態を
/// キャプチャできない）に渡すため、`Unmanaged` 経由で受け渡す参照型。
private final class PDFPageContentClassificationState {
    var hasTextOperator = false
    var hasImageDraw = false
}

private func pdfTextOperatorCallback(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<PDFPageContentClassificationState>.fromOpaque(info).takeUnretainedValue().hasTextOperator = true
}

/// `Do`（名前付きリソースの描画）演算子のコールバック。オペランドスタックから
/// リソース名を取り出し、現在のコンテンツストリームの `XObject` カテゴリから
/// 実体を引いて `/Subtype` が `Image` かどうかを見る（`Form` XObject は対象外
/// [既知の限界、`PDFThumbnailLoading` のドキュメントコメント参照]）。
///
/// **Image XObject は PDF の「stream オブジェクト」**（`<< /Type /XObject
/// /Subtype /Image ... >> stream ... endstream`、辞書と実データを両方持つ）
/// であり、`CGPDFObjectGetValue` で素の `.dictionary` として取り出そうとすると
/// 失敗する。`.stream`（`CGPDFStreamRef`）として取り出し、
/// `CGPDFStreamGetDictionary` でその辞書を得る必要がある
/// [実装中に発見: 単体スクリプトで `CGPDFObjectGetValue(..., .dictionary, ...)`
/// が常に失敗することを確認し、`CGPDFObjectType` に `.stream` が別途ある
/// ことに気づいて解決した]。
private func pdfDoOperatorCallback(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    var namePointer: UnsafePointer<Int8>?
    guard CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
    let contentStream = CGPDFScannerGetContentStream(scanner)
    guard let xObject = CGPDFContentStreamGetResource(contentStream, "XObject", namePointer) else { return }
    var xObjectStream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(xObject, .stream, &xObjectStream), let xObjectStream,
          let xObjectDictionary = CGPDFStreamGetDictionary(xObjectStream)
    else { return }
    var subtypeNamePointer: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(xObjectDictionary, "Subtype", &subtypeNamePointer), let subtypeNamePointer else { return }
    guard String(cString: subtypeNamePointer) == "Image" else { return }

    Unmanaged<PDFPageContentClassificationState>.fromOpaque(info).takeUnretainedValue().hasImageDraw = true
}
