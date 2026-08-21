//
//  メタデータ用の XML パース [EM-60][EM-61]。
//
//  **外部実体を解決しない設定をここ 1 箇所に集める。**呼び出し側が
//  `XMLParser` を直に組み立てると、いつか設定を忘れる。
//
import Foundation

/// メタデータでよく使う名前空間 URI。
public enum XMLNamespace {
    public static let dublinCore = "http://purl.org/dc/elements/1.1/"
    public static let opf = "http://www.idpf.org/2007/opf"
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let calibre = "http://calibre-ebook.com/xmp-namespace"
    public static let calibreSeriesIndex = "http://calibre-ebook.com/xmp-namespace-series-index"
}

/// **XML を安全にパースする唯一の入口。**`QooInfrastructure` からも使う
/// （EPUB の container.xml の解決）ため公開している——各層が `XMLParser` を
/// 直に組み立てられる状態にしておくと、いつか設定を忘れる。
public enum SafeXMLParsing {

    /// 上限つきで XML をパースする。
    ///
    /// - Note: `XMLParser`（libxml2）は**既定で安全**であることを実測で確かめた
    ///   （09章 §9.9）——`file://` の外部実体は解決されず、外部 DTD のために
    ///   ネットワークへも出ず、実体展開の爆発（billion laughs）はエラー 111 で
    ///   拒否される。**`resolveExternalEntityName(_:systemID:)` をデリゲートに
    ///   実装しないこと**：実装しなければ `nil` を返すのと同じで、外部実体は
    ///   解決されない。
    /// - Parameter maxBytes: これを超える文書は**切り詰めずに諦める** [EM-61]。
    ///   途中まで読むと、閉じタグの無い XML を部分的に解釈して誤った値を採る。
    public static func parse(_ data: Data,
                             delegate: XMLParserDelegate,
                             maxBytes: Int = AppLimits.Metadata.maxDocumentBytes) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true     // localName + namespaceURI で照合する
        parser.shouldResolveExternalEntities = false   // 既定だが、意図を明示する [EM-60]
        parser.delegate = delegate
        return parser.parse()
    }
}

/// 要素の文字を貯めるだけの土台。`foundCharacters` は**分割して届く**ため、
/// 1 回のコールバックで完結すると考えてはならない。
class TextAccumulatingParserDelegate: NSObject, XMLParserDelegate {
    /// 現在の要素に貯まっている文字。要素の開始で空にする。
    var buffer = ""
    /// ルートからの深さ（ルート要素が 1）。
    var depth = 0

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    /// 貯めた文字を取り出して空にする。
    func takeBuffer() -> String {
        defer { buffer = "" }
        return buffer
    }
}
