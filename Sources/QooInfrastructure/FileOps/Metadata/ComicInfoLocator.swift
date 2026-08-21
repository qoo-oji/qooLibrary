//
//  アーカイブ内の `ComicInfo.xml` を探す [EM-20][EM-21]。
//
//  **探索の規則だけを持つ純粋関数**。実ファイルには触らないので、エントリ一覧を
//  組み立てるだけで全パターンを試せる。
//
import Foundation
import QooKit

enum ComicInfoLocator {
    static let canonicalName = "ComicInfo.xml"

    /// 読むべき `ComicInfo.xml` のエントリ。無ければ `nil`。
    ///
    /// 探す場所は**ルート直下、または単一のトップレベルフォルダの直下まで** [EM-20]。
    /// 仕様（RFC-CBZ）はルート直下と定めるが、`作品名/ComicInfo.xml` という構造は
    /// 実際に多い。**トップレベルの項目が 2 つ以上あるなら、どれが本体か決められない
    /// のでルート直下しか見ない**——複数巻をまとめたアーカイブで誤った巻数を拾うより、
    /// 読まないほうが害が小さい。
    ///
    /// 大文字小文字は無視する [EM-21]。仕様は `ComicInfo.xml` を要求するが、
    /// 小文字で書き出すツールが実在する。ただし**完全一致を優先する**——
    /// 両方あるなら、仕様どおりの綴りのほうが意図して置かれた可能性が高い。
    static func find(in listing: ArchiveListing) -> ArchiveEntry? {
        let files = listing.entries.filter { !$0.isDirectory && !$0.isSymlink && !$0.isSpecialEntry }
        let candidates = files.filter {
            lastComponent($0.pathname).caseInsensitiveCompare(canonicalName) == .orderedSame
        }
        guard !candidates.isEmpty else { return nil }

        let root = candidates.filter { depth(of: $0.pathname) == 1 }
        if let exact = root.first(where: { $0.pathname == canonicalName }) { return exact }
        if let any = root.first { return any }

        guard let folder = singleTopLevelFolder(of: files) else { return nil }
        let nested = candidates.filter {
            depth(of: $0.pathname) == 2 && $0.pathname.hasPrefix(folder + "/")
        }
        if let exact = nested.first(where: { $0.pathname == "\(folder)/\(canonicalName)" }) {
            return exact
        }
        return nested.first
    }

    /// 全ファイルが同じトップレベルフォルダの下にあるなら、その名前。
    ///
    /// ルート直下にファイルが 1 つでもあれば `nil`——「単一のフォルダに包まれた
    /// アーカイブ」ではないため。
    static func singleTopLevelFolder(of files: [ArchiveEntry]) -> String? {
        var top: String?
        for file in files {
            let components = file.pathname.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 2 else { return nil }
            let first = String(components[0])
            if let top, top != first { return nil }
            top = first
        }
        return top
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}
