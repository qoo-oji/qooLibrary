import Foundation

/// テスト用の PDF をバイト列から組み立てる。
///
/// **`CGContext` の PDF 生成では XMP を書けない**（`kCGPDFContext*` に対応する
/// キーが無い）ため、`/Metadata` ストリームを持つ PDF を作るには手で組む
/// しかない [09章 §9.9]。構造は PDF 1.7 仕様（PDF32000-1:2008）の最小構成:
/// カタログ → ページツリー → 1 ページ、＋ 情報辞書、＋（任意で）XMP ストリーム。
enum PDFFixtureBuilder {

    /// Calibre が実際に書き出す形の XMP。
    static func calibreXMP(title: String, author: String,
                           series: String, seriesIndex: String) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(title)</rdf:li></rdf:Alt></dc:title>
           <dc:creator><rdf:Seq><rdf:li>\(author)</rdf:li></rdf:Seq></dc:creator>
          </rdf:Description>
          <rdf:Description rdf:about="" \
        xmlns:calibre="http://calibre-ebook.com/xmp-namespace" \
        xmlns:calibreSI="http://calibre-ebook.com/xmp-namespace-series-index">
           <calibre:series rdf:parseType="Resource">
            <rdf:value>\(series)</rdf:value>
            <calibreSI:series_index>\(seriesIndex)</calibreSI:series_index>
           </calibre:series>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// - Parameters:
    ///   - infoTitle: 文書情報辞書の `Title`。**UTF-16BE + BOM の 16 進文字列**で
    ///     書く（PDF Spec 7.9.2.2）——日本語が正しくデコードされることの検証を兼ねる。
    ///   - xmp: 非 nil ならカタログに `/Metadata` を持たせる。
    static func write(to url: URL, infoTitle: String?, infoAuthor: String?, xmp: String?) throws {
        var objects: [Data] = []
        let metadataRef = xmp == nil ? "" : " /Metadata 5 0 R"
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R\(metadataRef) >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] >>".utf8))

        var info = "<<"
        if let infoTitle { info += " /Title \(hexString(infoTitle))" }
        if let infoAuthor { info += " /Author \(hexString(infoAuthor))" }
        info += " >>"
        objects.append(Data(info.utf8))

        if let xmp {
            let payload = Data(xmp.utf8)
            var stream = Data("<< /Type /Metadata /Subtype /XML /Length \(payload.count) >>\nstream\n".utf8)
            stream.append(payload)
            stream.append(Data("\nendstream".utf8))
            objects.append(stream)
        }

        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        let size = objects.count + 1
        out.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data("""
        trailer
        << /Size \(size) /Root 1 0 R /Info 4 0 R >>
        startxref
        \(xrefOffset)
        %%EOF

        """.utf8))
        try out.write(to: url)
    }

    /// UTF-16BE + BOM の 16 進文字列（`<FEFF...>`）。
    private static func hexString(_ value: String) -> String {
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in Array(value.utf16) {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return "<" + bytes.map { String(format: "%02x", $0) }.joined() + ">"
    }
}
