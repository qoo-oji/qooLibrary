//
//  マニュアル（`MANUAL.md`）への導線 [HP-07][HP-08]。
//
//  網羅的な文法説明はアプリ内に持たず、設定画面の各項目からリポジトリの
//  `MANUAL.md` の該当する節を開く。**節の識別子はここに列挙したものが
//  すべて**で、`Scripts/check-manual-anchors.swift` が「その識別子の
//  `<a id="…">` が `MANUAL.md` に実在すること」を CI で検査する——
//  リンク先が実在しないうちはリンクを置かない、という決めごとを機械で守る。
//
import AppKit
import SwiftUI

/// `MANUAL.md` の節。`rawValue` がそのまま見出しのアンカー（`<a id="…">`）。
enum ManualSection: String, CaseIterable {
    case top
    case basics
    case fields
    case folderLevels = "folder-levels"
    case filenameFormats = "filename-formats"
    case extensions
    case volumeFormats = "volume-formats"
    case seriesTitle = "series-title"
    case delimiters
    case protectedTokens = "protected-tokens"
    case bookFolders = "book-folders"
}

enum ManualLink {
    /// 公開リポジトリ上の `MANUAL.md`。ネットワークへ何かを送る経路ではなく、
    /// 既定のブラウザへ URL を渡すだけ [SC-01 に抵触しない]。
    static let baseURL = URL(string: "https://github.com/qoo-oji/qooLibrary/blob/main/MANUAL.md")!

    static func url(for section: ManualSection) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.fragment = section == .top ? nil : section.rawValue
        return components.url!
    }

    @MainActor
    static func open(_ section: ManualSection) {
        NSWorkspace.shared.open(url(for: section))
    }
}

/// 設定項目の脇に置く「マニュアル」リンク [HP-07]。見た目は他の補助リンク
/// （`.buttonStyle(.link)`）と揃える。
struct ManualLinkButton: View {
    let section: ManualSection

    var body: some View {
        Button("manual.sectionLink") {
            ManualLink.open(section)
        }
        .buttonStyle(.link)
        .font(.system(size: Tokens.fontSize.caption))
    }
}
