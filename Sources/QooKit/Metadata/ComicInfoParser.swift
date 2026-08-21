//
//  ComicInfo.xml の解釈 [EM-20〜EM-28][05章 §5.7]。
//
//  スキーマは Anansi Project（ComicRack 由来）。v1.0 / v2.0 / v2.1(draft) を
//  通して **`Number` は `xs:string`、`Volume` は `xs:int`（既定 -1）** で、
//  この 2 つが実装によって真逆の意味で使われている。
//
import Foundation

public enum ComicInfoParser {

    /// - Parameter volumeSource: 巻数を `Number`／`Volume` のどちらから取るか [EM-30]。
    ///   `.ask` のとき、食い違えば `volumeConflict` を立てて巻数は未確定にする。
    public static func parse(_ data: Data,
                             volumeSource: ComicInfoVolumeSource = .ask) -> EmbeddedMetadata? {
        let delegate = Delegate()
        guard SafeXMLParsing.parse(data, delegate: delegate) else { return nil }
        guard delegate.sawComicInfoRoot else { return nil }

        let resolved = resolveVolume(number: delegate.number, volume: delegate.volume,
                                     source: volumeSource)
        return EmbeddedMetadata(
            source: .comicInfo,
            title: delegate.title,
            series: delegate.series,
            volume: resolved.volume,
            volumeRaw: resolved.raw,
            // `Writer` はカンマ区切りで複数を持てる [EM-27]。
            authors: splitNames(delegate.writer),
            volumeConflict: resolved.conflict)
    }

    // MARK: - 巻数の決着 [EM-25][EM-26][VM3-01〜VM3-05]

    struct ResolvedVolume {
        var volume: Double?
        var raw: String?
        var conflict: EmbeddedMetadata.VolumeConflict?
    }

    /// - Parameters:
    ///   - number: `Number` 要素の原文（`xs:string`）。
    ///   - volume: `Volume` 要素の原文（`xs:int`）。
    static func resolveVolume(number: String?, volume: String?,
                              source: ComicInfoVolumeSource) -> ResolvedVolume {
        let n = numericNumber(number)
        let v = numericVolume(volume)

        switch (n, v) {
        case (nil, nil):
            return ResolvedVolume()
        case (let n?, nil):
            return ResolvedVolume(volume: n.value, raw: n.raw)          // [EM-25]
        case (nil, let v?):
            return ResolvedVolume(volume: v.value, raw: v.raw)          // [EM-25]
        case (let n?, let v?):
            if n.value == v.value {
                return ResolvedVolume(volume: n.value, raw: n.raw)      // [EM-25]
            }
            switch source {
            case .number: return ResolvedVolume(volume: n.value, raw: n.raw)
            case .volume: return ResolvedVolume(volume: v.value, raw: v.raw)
            case .ask:
                // **巻数は未確定のままにする** [VM3-03]。どちらか分からない値を
                // 採るくらいなら、ファイル名から抽出した値のほうが確からしい。
                return ResolvedVolume(volume: nil, raw: nil,
                                      conflict: .init(number: n.value, numberRaw: n.raw,
                                                      volume: v.value, volumeRaw: v.raw))
            }
        }
    }

    /// `Number`（`xs:string`）を数として読む [EM-24]。
    ///
    /// **`3.5` のような小数は認める**（話数を巻数として使う運用がある）。
    /// `Special` のように数として読めない値は**巻数として採らない**——
    /// 0 に丸めると「第 0 巻」という嘘になる。
    static func numericNumber(_ raw: String?) -> (value: Double, raw: String)? {
        guard let trimmed = raw.flatMap(EmbeddedMetadata.cleaned) else { return nil }
        guard let value = Double(trimmed) else { return nil }
        guard value.isFinite else { return nil }
        return (value, trimmed)
    }

    /// `Volume`（`xs:int`、既定 `-1`）を数として読む [EM-23]。
    ///
    /// **負の値と 0 は未設定**として扱う。`-1` は XSD の既定値そのもので、
    /// 書き出したツールが埋めなかっただけである。
    static func numericVolume(_ raw: String?) -> (value: Double, raw: String)? {
        guard let trimmed = raw.flatMap(EmbeddedMetadata.cleaned) else { return nil }
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return (value, trimmed)
    }

    /// カンマ区切りの名前を分割する [EM-27]。
    static func splitNames(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").compactMap { EmbeddedMetadata.cleaned(String($0)) }
    }

    // MARK: - 走査

    private final class Delegate: TextAccumulatingParserDelegate {
        var sawComicInfoRoot = false
        var title: String?
        var series: String?
        var number: String?
        var volume: String?
        var writer: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth == 1, elementName == "ComicInfo" { sawComicInfoRoot = true }
            buffer = ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            defer { depth -= 1; buffer = "" }
            // **ルート直下の要素だけを見る。**`Pages > Page` のような入れ子の
            // 中に同名の要素があっても拾わない。
            guard depth == 2 else { return }
            let text = buffer
            switch elementName {
            case "Title":  title = text
            case "Series": series = text
            case "Number": number = text
            case "Volume": volume = text
            case "Writer": writer = text
            default: break
            }
        }
    }
}
