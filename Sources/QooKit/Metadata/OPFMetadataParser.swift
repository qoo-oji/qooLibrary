//
//  EPUB の package document（OPF）の `<metadata>` の解釈 [EM-40〜EM-46]。
//
//  **EPUB 3 の記法と Calibre 独自拡張（EPUB 2 流）の両方を読む** [EM-45]。
//  日本語の電子書籍は EPUB 3 が主流だが、Calibre を通したものは独自拡張を持つ。
//  両方ある場合は EPUB 3 を優先する [EM-46]——標準の記法のほうが、書いた側が
//  意図して埋めた可能性が高い。
//
import Foundation

public enum OPFMetadataParser {

    public static func parse(_ data: Data) -> EmbeddedMetadata? {
        let delegate = Delegate()
        guard SafeXMLParsing.parse(data, delegate: delegate) else { return nil }
        guard delegate.sawMetadata else { return nil }

        let series = resolveSeries(delegate)
        return EmbeddedMetadata(
            source: .epub,
            title: resolveTitle(delegate),
            series: series.name,
            volume: series.index,
            volumeRaw: series.indexRaw,
            authors: resolveAuthors(delegate))
    }

    // MARK: - タイトル [EM-41]

    /// `title-type` が `main` のものを優先し、無ければ最初の `dc:title` を使う。
    ///
    /// 副題や叢書名も `dc:title` として並ぶことがあるので、**最初のものが
    /// 本題とは限らない**。
    static func resolveTitle(_ d: Delegate) -> String? {
        let mainIDs = Set(d.metas.filter { $0.property == "title-type" && $0.text == "main" }
                                 .compactMap(\.refinesID))
        if let main = d.titles.first(where: { $0.id.map(mainIDs.contains) ?? false }) {
            return main.text
        }
        return d.titles.first?.text
    }

    // MARK: - 著者 [EM-42]

    /// 役割が `aut` の `dc:creator` を優先する。
    ///
    /// 役割の指定が無い `dc:creator` は著者と見なす——実際の EPUB では役割を
    /// 書かないものが多く、そこで諦めると大半で著者が取れない（Kavita も
    /// 同じ扱いをしている）。**ただし他の役割（`ill` = 挿絵など）が明示
    /// されているものは著者にしない。**
    static func resolveAuthors(_ d: Delegate) -> [String] {
        var roleByID: [String: String] = [:]
        for meta in d.metas where meta.property == "role" {
            // `scheme` が指定されていて `marc:relators` でないなら、別の語彙。
            if let scheme = meta.scheme, scheme != "marc:relators" { continue }
            guard let id = meta.refinesID, let text = meta.text else { continue }
            roleByID[id] = text
        }
        func role(of creator: Element) -> String? {
            creator.opfRole ?? creator.id.flatMap { roleByID[$0] }
        }
        let authors = d.creators.filter { role(of: $0) == "aut" }
        if !authors.isEmpty { return authors.compactMap(\.text) }
        return d.creators.filter { role(of: $0) == nil }.compactMap(\.text)
    }

    // MARK: - シリーズ [EM-43〜EM-46]

    struct ResolvedSeries {
        var name: String?
        var index: Double?
        var indexRaw: String?
    }

    static func resolveSeries(_ d: Delegate) -> ResolvedSeries {
        if let epub3 = resolveEPUB3Series(d) { return epub3 }        // [EM-46] 優先
        return resolveCalibreSeries(d)
    }

    /// EPUB 3: `belongs-to-collection` ＋ `refines` で結ばれた `group-position` [EM-43]。
    ///
    /// **`collection-type` が `series` のものを優先する** [EM-44]。`set`（作品集）を
    /// シリーズ名として採ると、別の作品どうしが同じシリーズに見える。
    /// 指定が無いものは `series` と見なす——実際の EPUB では省かれることが多い。
    static func resolveEPUB3Series(_ d: Delegate) -> ResolvedSeries? {
        let collections = d.metas.filter { $0.property == "belongs-to-collection" }
        guard !collections.isEmpty else { return nil }

        var typeByID: [String: String] = [:]
        for meta in d.metas where meta.property == "collection-type" {
            guard let id = meta.refinesID, let text = meta.text else { continue }
            typeByID[id] = text
        }
        func kind(of collection: Meta) -> String? {
            collection.id.flatMap { typeByID[$0] }
        }
        // ① type が series ②type の指定が無い の順で探す。`set` しか無ければ採らない。
        let chosen = collections.first { kind(of: $0) == "series" }
            ?? collections.first { kind(of: $0) == nil }
        guard let chosen, let name = chosen.text else { return nil }

        var out = ResolvedSeries(name: name)
        if let id = chosen.id,
           let position = d.metas.first(where: { $0.property == "group-position" && $0.refinesID == id }),
           let raw = position.text.flatMap(EmbeddedMetadata.cleaned),
           let value = Double(raw), value.isFinite {
            out.index = value
            out.indexRaw = raw
        }
        return out
    }

    /// EPUB 2（Calibre 独自拡張）: `<meta name="calibre:series" content="…"/>` [EM-45]。
    static func resolveCalibreSeries(_ d: Delegate) -> ResolvedSeries {
        var out = ResolvedSeries()
        out.name = d.metas.first { $0.name == "calibre:series" }?.content
        if let raw = d.metas.first(where: { $0.name == "calibre:series_index" })?.content
            .flatMap(EmbeddedMetadata.cleaned),
           let value = Double(raw), value.isFinite {
            out.index = value
            out.indexRaw = raw
        }
        // シリーズ名が無ければ巻数だけ持っていても意味を成さない。
        if out.name == nil { return ResolvedSeries() }
        return out
    }

    // MARK: - 走査

    struct Element {
        var id: String?
        /// EPUB 2 流の `opf:role="aut"`。
        var opfRole: String?
        var text: String?
    }

    struct Meta {
        var id: String?
        var property: String?      // EPUB 3
        var refinesID: String?     // EPUB 3（`#id` から `#` を落としたもの）
        var scheme: String?        // EPUB 3
        var name: String?          // EPUB 2
        var content: String?       // EPUB 2
        var text: String?          // EPUB 3 は要素のテキストが値
    }

    final class Delegate: TextAccumulatingParserDelegate {
        var sawMetadata = false
        var titles: [Element] = []
        var creators: [Element] = []
        var metas: [Meta] = []

        private var inMetadata = false
        private var pendingElement: Element?
        private var pendingElementKind: Kind?
        private var pendingMeta: Meta?

        private enum Kind { case title, creator }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            depth += 1
            buffer = ""
            if elementName == "metadata" {
                inMetadata = true
                sawMetadata = true
                return
            }
            guard inMetadata else { return }

            switch elementName {
            case "title" where namespaceURI == XMLNamespace.dublinCore || namespaceURI == nil:
                pendingElementKind = .title
                pendingElement = Element(id: attributeDict["id"], opfRole: nil, text: nil)
            case "creator" where namespaceURI == XMLNamespace.dublinCore || namespaceURI == nil:
                pendingElementKind = .creator
                // `shouldProcessNamespaces = true` でも、**属性名は接頭辞付きのまま**
                // 届く（属性の名前空間は展開されない）。`opf:role` をそのまま引く。
                pendingElement = Element(id: attributeDict["id"],
                                         opfRole: attributeDict["opf:role"] ?? attributeDict["role"],
                                         text: nil)
            case "meta":
                pendingMeta = Meta(
                    id: attributeDict["id"],
                    property: attributeDict["property"],
                    refinesID: attributeDict["refines"].map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 },
                    scheme: attributeDict["scheme"],
                    name: attributeDict["name"],
                    content: attributeDict["content"],
                    text: nil)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            defer { depth -= 1; buffer = "" }
            if elementName == "metadata" { inMetadata = false; return }
            guard inMetadata else { return }

            let text = EmbeddedMetadata.cleaned(buffer)
            switch elementName {
            case "title", "creator":
                guard var element = pendingElement, let kind = pendingElementKind else { break }
                element.text = text
                if element.text != nil {
                    if kind == .title { titles.append(element) } else { creators.append(element) }
                }
                pendingElement = nil
                pendingElementKind = nil
            case "meta":
                guard var meta = pendingMeta else { break }
                meta.text = text
                metas.append(meta)
                pendingMeta = nil
            default:
                break
            }
        }
    }
}
