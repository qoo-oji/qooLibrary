//
//  PDF の文書情報辞書と XMP を取り出す [EM-50〜EM-55]。
//
//  **CoreGraphics だけで完結する**（PDFKit 等の追加依存は要らない）。手で
//  組み立てた最小 PDF に対して、情報辞書の UTF-16BE 文字列（日本語）と
//  カタログの `/Metadata` ストリームの両方が取れることを実測で確かめた
//  [09章 §9.9]。
//
import CoreGraphics
import Foundation
import QooKit

enum PDFMetadataExtractor {

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]。
    ///   ネットワーク上の PDF は `openDocument` が読み切ってから開く [NV6-08]。
    static func read(_ url: URL) -> EmbeddedMetadata? {
        guard let document = CoreGraphicsPDFThumbnailLoader.openDocument(at: url) else { return nil }
        // 暗号化された PDF は読まない [EM-55]。空パスワードで開ける場合も
        // あるが、そこまでして読む価値のあるメタデータではない。
        guard !document.isEncrypted else { return nil }

        let xmp = xmpPacket(of: document).flatMap(XMPMetadataParser.parse)
        return PDFMetadataComposer.compose(xmp: xmp, info: infoFields(of: document))
    }

    /// 文書カタログの `/Metadata`（XMP パケット）。
    static func xmpPacket(of document: CGPDFDocument) -> Data? {
        guard let catalog = document.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        // 圧縮された XMP は仕様上あり得ないが、来たら諦める（伸長しない）。
        guard format == .raw else { return nil }
        guard data.count <= AppLimits.Metadata.maxDocumentBytes else { return nil }
        return data
    }

    /// 文書情報辞書（`/Info`）の `Title` と `Author` [EM-52]。
    static func infoFields(of document: CGPDFDocument) -> PDFInfoFields {
        guard let info = document.info else { return PDFInfoFields() }
        return PDFInfoFields(title: string(info, "Title"), author: string(info, "Author"))
    }

    /// `CGPDFStringCopyTextString` は PDFDocEncoding と UTF-16BE(BOM 付き) の
    /// どちらも扱う（PDF Spec 7.9.2.2）。日本語が正しくデコードされることは実測済み。
    private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }
}
