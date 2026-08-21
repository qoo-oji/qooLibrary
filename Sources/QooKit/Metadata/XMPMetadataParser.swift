//
//  XMP（PDF の文書カタログ `/Metadata`）の解釈 [EM-51][EM-53]。
//
//  **シリーズと巻数は Calibre 互換の記法のみを読む** [EM-53][EM-54]。PDF には
//  シリーズを表す標準的なフォーマットが存在しない。Calibre は専用の名前空間へ
//  書き込んでおり、Kavita も同じ場所を読んでいる——ここに絞ることで、既存の
//  ツールで書けて、他のリーダーとも互換になる。
//
//  ```xml
//  <calibre:series rdf:parseType="Resource">
//    <rdf:value>シリーズ名</rdf:value>
//    <calibreSI:series_index>3.00</calibreSI:series_index>
//  </calibre:series>
//  ```
//
import Foundation

public enum XMPMetadataParser {

    public static func parse(_ data: Data) -> EmbeddedMetadata? {
        let delegate = Delegate()
        guard SafeXMLParsing.parse(data, delegate: delegate) else { return nil }

        var index: Double?
        var indexRaw: String?
        // シリーズ名が無ければ巻数だけ持っていても意味を成さない。
        if delegate.series != nil,
           let raw = delegate.seriesIndex.flatMap(EmbeddedMetadata.cleaned),
           let value = Double(raw), value.isFinite {
            index = value
            // `3.00` のような書き方をそのまま巻数表記に使うと `第3.00巻` になる。
            // **値から表記を作り直す**——原文の桁揃えは Calibre の都合であって、
            // 利用者が入力した表記ではない。
            indexRaw = formatIndex(value)
        }
        return EmbeddedMetadata(
            source: .pdf,
            title: delegate.title,
            series: delegate.series,
            volume: index,
            volumeRaw: indexRaw,
            authors: delegate.creators)
    }

    /// `3.00` → `3`、`3.50` → `3.5`。
    static func formatIndex(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - 走査

    private final class Delegate: TextAccumulatingParserDelegate {
        var title: String?
        var creators: [String] = []
        var series: String?
        var seriesIndex: String?

        /// 要素のスタック。`(namespaceURI, localName)`。XMP は RDF なので
        /// 入れ子が深く、**どの親の下にいるか**でしか値の意味が決まらない。
        private var stack: [(ns: String?, name: String)] = []

        private func isInside(ns: String, name: String) -> Bool {
            stack.contains { $0.ns == ns && $0.name == name }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            stack.append((namespaceURI, elementName))
            buffer = ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let text = EmbeddedMetadata.cleaned(buffer)
            defer {
                if !stack.isEmpty { stack.removeLast() }
                buffer = ""
            }
            guard let text else { return }
            // 自分自身はスタックの末尾にいるので、親の判定からは外して見る。
            let parents = stack.dropLast()
            func inside(_ ns: String, _ name: String) -> Bool {
                parents.contains { $0.ns == ns && $0.name == name }
            }

            switch (namespaceURI, elementName) {
            case (XMLNamespace.calibreSeriesIndex, "series_index"):
                if seriesIndex == nil { seriesIndex = text }

            case (XMLNamespace.rdf, "value") where inside(XMLNamespace.calibre, "series"):
                if series == nil { series = text }

            case (XMLNamespace.rdf, "li"):
                // `dc:title` は `rdf:Alt`、`dc:creator` は `rdf:Seq` に包まれる。
                if inside(XMLNamespace.dublinCore, "title") {
                    if title == nil { title = text }
                } else if inside(XMLNamespace.dublinCore, "creator") {
                    creators.append(text)
                }

            case (XMLNamespace.dublinCore, "title"):
                // 包まずに直接書く簡略記法。子要素があれば上の分岐で拾い済み。
                if title == nil { title = text }

            case (XMLNamespace.dublinCore, "creator"):
                if creators.isEmpty { creators.append(text) }

            case (XMLNamespace.calibre, "series"):
                // `rdf:parseType="Resource"` でなく、値を直接書く形。
                if series == nil { series = text }

            default:
                break
            }
        }
    }
}

/// PDF の文書情報辞書（`/Info`）から読める分 [EM-52]。
///
/// XMP を持たない PDF のためのフォールバックで、**シリーズと巻数は持てない**
/// （辞書に対応するキーが無い）。
public struct PDFInfoFields: Sendable, Hashable {
    public var title: String?
    public var author: String?

    public init(title: String? = nil, author: String? = nil) {
        self.title = title
        self.author = author
    }

    public var isEmpty: Bool { title == nil && author == nil }
}

public enum PDFMetadataComposer {

    /// XMP を優先し、無いフィールドだけ情報辞書で補う [EM-50]。
    ///
    /// **フィールド単位で補う。**XMP がタイトルだけ持つ PDF は実在し、
    /// 「XMP があるなら辞書は見ない」とすると著者を取り落とす。
    public static func compose(xmp: EmbeddedMetadata?, info: PDFInfoFields) -> EmbeddedMetadata? {
        let infoAuthors = info.author.map { ComicInfoParser.splitNames($0) } ?? []
        guard let xmp else {
            guard !info.isEmpty else { return nil }
            let composed = EmbeddedMetadata(source: .pdf, title: info.title, authors: infoAuthors)
            return composed.isEmpty ? nil : composed
        }
        let composed = EmbeddedMetadata(
            source: .pdf,
            title: xmp.title ?? info.title,
            series: xmp.series,
            volume: xmp.volume,
            volumeRaw: xmp.volumeRaw,
            authors: xmp.authors.isEmpty ? infoAuthors : xmp.authors)
        return composed.isEmpty ? nil : composed
    }
}
