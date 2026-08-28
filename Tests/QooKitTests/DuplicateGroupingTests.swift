import Foundation
import Testing

@testable import QooKit

/// [2-18] 重複の判定キー [DU-02][DU-03] と、代表・残す 1 件の決定
/// [DU-05][DU-08][DU-25]。
///
/// **標本は実際に扱う形にする**（`(同人誌) [サークル値A] …` の類）——
/// きれいな例だけを標本にすると、その分野で最も普通の入力を取りこぼす
/// （CLAUDE.md の既記録の教訓）。
struct DuplicateGroupingTests {

    private func row(_ id: Int64, name: String, title: String?,
                     volume: VolumeValue = .none, rating: Int = 0,
                     size: Int64 = 100,
                     pages: Int? = nil, width: Int? = nil, height: Int? = nil) -> FileRow {
        FileRow(id: FileID(rawValue: id), libraryID: LibraryID(rawValue: 1),
                relativePath: name, filename: name, fileSize: size,
                createdAt: .distantPast, modifiedAt: .distantPast,
                title: title, seriesName: nil, volume: volume, rating: rating,
                state: .active, isArchived: false, isBookFolder: false,
                pageCount: pages, firstImageWidth: width, firstImageHeight: height)
    }

    // MARK: - 判定キー [DU-02][DU-03]

    @Test func offNeverGroups() {
        #expect(DuplicateGroupKey.make(title: "作品名A", volume: .none, mode: .off) == nil)
    }

    /// **タイトルを取れなかったファイルはグループ化の対象にしない。**
    ///
    /// `nil` どうしを同じ鍵とみなすと、未解決ファイル [AL-30] が全部 1 つの
    /// 巨大なグループになる——蔵書によっては数千件で、実害になる。
    @Test func filesWithoutATitleAreNotGrouped() {
        #expect(DuplicateGroupKey.make(title: nil, volume: .none, mode: .byTitle) == nil)
        #expect(DuplicateGroupKey.make(title: "", volume: .none, mode: .byTitle) == nil)
        #expect(DuplicateGroupKey.make(title: "   ", volume: .none, mode: .byTitle) == nil)
    }

    /// 正規化は N-01〜N-03 + WS-06 [DU-03]。全角・大小・空白の差を吸収する。
    @Test func normalizesTitleBeforeComparing() {
        let a = DuplicateGroupKey.make(title: "作品名Ａ　ＶＯＬ", volume: .none, mode: .byTitle)
        let b = DuplicateGroupKey.make(title: "作品名A vol", volume: .none, mode: .byTitle)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func byTitleIgnoresVolume() {
        let a = DuplicateGroupKey.make(title: "作品名A", volume: .numeric(1, raw: "第01巻"),
                                       mode: .byTitle)
        let b = DuplicateGroupKey.make(title: "作品名A", volume: .numeric(2, raw: "第02巻"),
                                       mode: .byTitle)
        #expect(a == b)
    }

    @Test func byTitleAndVolumeSeparatesDifferentVolumes() {
        let a = DuplicateGroupKey.make(title: "作品名A", volume: .numeric(1, raw: "第01巻"),
                                       mode: .byTitleAndVolume)
        let b = DuplicateGroupKey.make(title: "作品名A", volume: .numeric(2, raw: "第02巻"),
                                       mode: .byTitleAndVolume)
        #expect(a != b)
    }

    /// 巻数を持たないもの**どうし**は同じ鍵にする——読み切り 2 冊は
    /// 同じ作品でありうる。
    @Test func byTitleAndVolumeGroupsVolumelessFilesTogether() {
        let a = DuplicateGroupKey.make(title: "作品名A", volume: .none, mode: .byTitleAndVolume)
        let b = DuplicateGroupKey.make(title: "作品名A", volume: .none, mode: .byTitleAndVolume)
        #expect(a != nil)
        #expect(a == b)
    }

    /// `3` と `3.0` は同じ巻。表記の揺れで別グループにしない。
    @Test func integralVolumeNumbersCompareEqually() {
        let a = DuplicateGroupKey.volumeKey(.numeric(3, raw: "第03巻"))
        let b = DuplicateGroupKey.volumeKey(.numeric(3.0, raw: "3"))
        #expect(a == b)
        #expect(DuplicateGroupKey.volumeKey(.numeric(3.5, raw: "3.5")) != a)
    }

    @Test func unknownStoredValueFallsBackToOff() {
        #expect(DuplicateGrouping(storedValue: nil) == .off)
        #expect(DuplicateGrouping(storedValue: "banana") == .off)
        #expect(DuplicateGrouping(storedValue: "byTitle") == .byTitle)
    }

    // MARK: - 代表の決定 [DU-05]

    @Test func ratingBeatsSize() {
        let rated = row(1, name: "z.cbz", title: "A", rating: 3, size: 1)
        let big = row(2, name: "a.cbz", title: "A", rating: 0, size: 999)
        #expect(DuplicateSelection.representative(of: [big, rated])?.id == rated.id)
    }

    @Test func sizeBeatsName() {
        let big = row(1, name: "z.cbz", title: "A", size: 999)
        let small = row(2, name: "a.cbz", title: "A", size: 1)
        #expect(DuplicateSelection.representative(of: [small, big])?.id == big.id)
    }

    /// 名前は**自然順**で比べる [DU-05]——素の `<` だと `第10巻` が `第2巻` より
    /// 前に来る。
    @Test func nameTieBreakUsesNaturalOrder() {
        let v2 = row(1, name: "作品名A 第2巻.cbz", title: "A")
        let v10 = row(2, name: "作品名A 第10巻.cbz", title: "A")
        #expect(DuplicateSelection.representative(of: [v10, v2])?.id == v2.id)
    }

    /// 名前まで同じでも順序が揺れないこと——代表が実行のたびに入れ替わって
    /// 見えるのを防ぐ。
    @Test func orderIsStableWhenEverythingTies() {
        let a = row(7, name: "同じ名前.cbz", title: "A")
        let b = row(3, name: "同じ名前.cbz", title: "A")
        #expect(DuplicateSelection.representative(of: [a, b])?.id == b.id)
        #expect(DuplicateSelection.representative(of: [b, a])?.id == b.id)
    }

    // MARK: - 残す 1 件の決定 [DU-25]

    @Test func keepsLargest() {
        let rows = [row(1, name: "a.cbz", title: "A", size: 10),
                    row(2, name: "b.cbz", title: "A", size: 900),
                    row(3, name: "c.cbz", title: "A", size: 500)]
        #expect(DuplicateSelection.keep(.largestSize, from: rows)?.id.rawValue == 2)
    }

    @Test func keepsMostPagesAndHighestRating() {
        let rows = [row(1, name: "a.cbz", title: "A", rating: 1, pages: 10),
                    row(2, name: "b.cbz", title: "A", rating: 5, pages: 200)]
        #expect(DuplicateSelection.keep(.mostPages, from: rows)?.id.rawValue == 2)
        #expect(DuplicateSelection.keep(.highestRating, from: rows)?.id.rawValue == 2)
    }

    @Test func keepsHighestResolution() {
        let rows = [row(1, name: "a.cbz", title: "A", width: 800, height: 1200),
                    row(2, name: "b.cbz", title: "A", width: 1600, height: 2400)]
        #expect(DuplicateSelection.keep(.highestResolution, from: rows)?.id.rawValue == 2)
    }

    /// **まだ数えていない値で勝たせない** [DU-22]。
    ///
    /// ページ数が `nil`（未取得）のファイルは、数え終わったファイルに
    /// 負ける——「取得できていないから 0 件」と「本当に 0 件」を
    /// 取り違えると、中身のあるほうを捨てることになる。
    @Test func unmeasuredPageCountsNeverWin() {
        let measured = row(1, name: "a.cbz", title: "A", size: 1, pages: 5)
        let unmeasured = row(2, name: "b.cbz", title: "A", size: 999, pages: nil)
        #expect(DuplicateSelection.keep(.mostPages, from: [unmeasured, measured])?.id
                == measured.id)
    }

    /// 全件が未取得なら規則は何も決めず、代表と同じ 1 件になる。
    @Test func allUnmeasuredFallsBackToRepresentativeOrder() {
        let rows = [row(1, name: "z.cbz", title: "A", size: 1),
                    row(2, name: "a.cbz", title: "A", size: 999)]
        #expect(DuplicateSelection.keep(.mostPages, from: rows)?.id
                == DuplicateSelection.representative(of: rows)?.id)
    }

    @Test func prefersDeclaredFormats() {
        let rows = [row(1, name: "作品.zip", title: "A", size: 999),
                    row(2, name: "作品.cbz", title: "A", size: 1)]
        #expect(DuplicateSelection.keep(.preferFormats(["cbz", "zip"]), from: rows)?
                .id.rawValue == 2)
        // 並びを逆にすれば結果も逆になる（表の順が効いていることの確認）。
        #expect(DuplicateSelection.keep(.preferFormats(["zip", "cbz"]), from: rows)?
                .id.rawValue == 1)
    }

    /// 一覧に無い形式は最下位。指定した形式が 1 件でもあれば必ずそちらが残る。
    @Test func formatsOutsideThePreferenceListLose() {
        let rows = [row(1, name: "作品.epub", title: "A", size: 999),
                    row(2, name: "作品.cbz", title: "A", size: 1)]
        #expect(DuplicateSelection.keep(.preferFormats(["cbz"]), from: rows)?.id.rawValue == 2)
    }

    @Test func emptyInputHasNoAnswer() {
        #expect(DuplicateSelection.representative(of: []) == nil)
        #expect(DuplicateSelection.keep(.largestSize, from: []) == nil)
    }
}
