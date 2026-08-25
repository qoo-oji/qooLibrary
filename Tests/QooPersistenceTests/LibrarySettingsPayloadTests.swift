import Foundation
import QooKit
import Testing
@testable import QooPersistence

//
//  `library.settingsJSON` の往復。
//
//  この型は `init(from:)` を**手で書いている**（既存の DB に保存済みの JSON を
//  読むので、フィールドを足すたびに古い行が読めなくなってはならないため
//  `decodeIfPresent` で読む）。その代償として、**フィールドを足しても
//  デコード側に 1 行足さないと黙って既定値に落ちる**——`CodingKeys` は
//  プロパティから合成されるので鍵だけは増え、コンパイラは何も言わない。
//  [IF-18] の設定を足したときに実際にこの穴へ落ちた。
//

@Suite("ライブラリ設定 JSON の往復")
struct LibrarySettingsPayloadTests {

    /// **すべてのフィールドを既定と違う値にすること。** 既定値のままだと、
    /// デコードで落ちても再エンコードが一致してしまい、検査が空振りする。
    private func fullyPopulated() -> LibrarySettingsPayload {
        LibrarySettingsPayload(
            targetExtensions: ["cbz", "zip"],
            imageExtensions: ["jpg"],
            delimiters: DelimiterSet(
                pairs: [PairDelimiter(open: "【", close: "】", isEnabled: true)],
                separators: [SeparatorDelimiter(canonical: "-", isEnabled: true)]),
            semanticBindings: ["@author": 3],
            seriesTitleCompositionFormat: "@series 第@volume巻",
            labelGroupOrder: [3, 1, 2],
            readsEmbeddedMetadata: false,
            comicInfoVolumeSource: .number,
            opensBookFolderWithApp: true)
    }

    /// 足したフィールドが**読み戻される**ことを、フィールドを列挙せずに固定する。
    /// 1 つでもデコードされないと、再エンコードした JSON が既定値に戻って
    /// 食い違う。
    @Test("payload に足したフィールドは必ず往復する")
    func everyFieldSurvivesARoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(fullyPopulated())
        let decoded = try JSONDecoder().decode(LibrarySettingsPayload.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(first == second,
                """
                往復で値が変わった。`LibrarySettingsPayload.init(from:)` に \
                デコードの行を足し忘れていないか確かめること。
                """)
    }

    /// 古い DB の JSON（新しい鍵が無い）でも読めること。これが `decodeIfPresent`
    /// を手で書いている理由そのもの。
    @Test("キーが無い古い JSON でも既定値で読める")
    func oldJSONStillDecodes() throws {
        let old = Data(#"{"targetExtensions":["cbz"]}"#.utf8)
        let payload = try JSONDecoder().decode(LibrarySettingsPayload.self, from: old)
        #expect(payload.targetExtensions == ["cbz"])
        #expect(payload.readsEmbeddedMetadata)          // 既定 true
        #expect(!payload.opensBookFolderWithApp)        // 既定 false [IF-18]
    }
}
