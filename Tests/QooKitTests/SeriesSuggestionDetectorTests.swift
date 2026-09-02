import Foundation
import Testing

@testable import QooKit

/// [ステージ 10] シリーズのヒューリスティック検出 [SS-01〜SS-08、19章 §19.5]。
///
/// **標本は実際に扱う形にする**——同人誌のタイトルは「1 冊目にだけ番号が
/// 無い」「続編に番号が付く」という形が要点で、きれいな連番だけを並べると
/// この機能が救おうとしている状況を 1 つも試さないことになる。
/// 実在の作品名は使わない [MT-32]。
struct SeriesSuggestionDetectorTests {

    private func book(_ id: Int64, _ title: String,
                      folder: String = "作者A",
                      keys: Set<String> = ["著者値1"],
                      ignored: Bool = false) -> SeriesSuggestionCandidate {
        SeriesSuggestionCandidate(id: FileID(rawValue: id), title: title,
                                  folderPath: folder, groupingKeys: keys,
                                  isIgnored: ignored)
    }

    // MARK: - 正例

    @Test("1 冊目に番号が無い形をまとめ、その 1 冊目には巻数を付けない [SS-07]")
    func firstVolumeWithoutANumber() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "催眠アプリ試作"),
            book(2, "催眠アプリ試作2"),
            book(3, "催眠アプリ試作3"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "催眠アプリ試作")
        #expect(out[0].members.map(\.volume.number) == [nil, 2, 3])
    }

    @Test("素の連番をまとめる")
    func plainNumbering() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1"),
            book(2, "作品タイトル2"),
            book(3, "作品タイトル3"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "作品タイトル")
        #expect(out[0].members.map(\.volume.number) == [1, 2, 3])
    }

    @Test("区切り記号で終わる接頭辞は、残りが数字でなくてもまとめる [SS-03](b)")
    func separatorBoundary() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル - 前編"),
            book(2, "作品タイトル - 後編"),
        ])
        #expect(out.count == 1)
        // **末尾の記号・空白は落とす** [SS-03]
        #expect(out[0].seriesName == "作品タイトル")
        #expect(out[0].members.allSatisfy { $0.volume.kind == .none })
    }

    @Test("全角数字でも巻数として読み、シリーズ名は原文の綴りで返す [SS-03]")
    func fullWidthDigits() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品ＴＩＴＬＥ１"),
            book(2, "作品ＴＩＴＬＥ２"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "作品ＴＩＴＬＥ")   // 原文のまま
        #expect(out[0].members.map(\.volume.number) == [1, 2])
    }

    @Test("大小の違いは同一視して照合する")
    func caseInsensitiveMatching() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "Studio Sample 1"),
            book(2, "STUDIO SAMPLE 2"),
        ])
        #expect(out.count == 1)
        #expect(out[0].members.map(\.volume.number) == [1, 2])
    }

    @Test("数字の途中で切らない（1 と 10 を 0 巻にしない）")
    func doesNotCutInTheMiddleOfANumber() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1"),
            book(2, "作品タイトル10"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "作品タイトル")
        #expect(out[0].members.map(\.volume.number) == [1, 10])
    }

    @Test("小数の巻数も読む")
    func decimalVolume() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1"),
            book(2, "作品タイトル1.5"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "作品タイトル")
        #expect(out[0].members.map(\.volume.number) == [1, 1.5])
    }

    @Test("著者が違ってもサークルが一致すればまとめる [SS-02]")
    func matchesOnCircleWhenAuthorsDiffer() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "合同誌タイトル1", keys: ["著者値1", "サークル値A"]),
            book(2, "合同誌タイトル2", keys: ["著者値2", "サークル値A"]),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "合同誌タイトル")
    }

    // MARK: - 負例

    @Test("境界が無ければまとめない（共通部分が語の途中）[SS-03]")
    func rejectsPrefixThatEndsMidWord() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "教師と生徒の話"),
            book(2, "教師と生活の話"),
        ])
        #expect(out.isEmpty)
    }

    @Test("巻数の印が数字の後ろに続く形はまとめない（作品名 第01巻）")
    func rejectsWhenTheRemainderIsNotAPlainNumber() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品名A 第01巻"),
            book(2, "作品名A 第02巻"),
        ])
        #expect(out.isEmpty)
    }

    @Test("シリーズ名が短すぎればまとめない [SS-02]")
    func rejectsTooShortAName() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "AB1"),
            book(2, "AB2"),
        ])
        #expect(out.isEmpty)
    }

    @Test("2 冊揃わなければ提案しない [SS-04]")
    func requiresTwoBooks() {
        let out = SeriesSuggestionDetector.detect([book(1, "作品タイトル1")])
        #expect(out.isEmpty)
    }

    @Test("フォルダが違えばまとめない [SS-02]")
    func requiresTheSameFolder() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1", folder: "作者A"),
            book(2, "作品タイトル2", folder: "作者B"),
        ])
        #expect(out.isEmpty)
    }

    @Test("著者もサークルも一致しなければまとめない [SS-02]")
    func requiresAMatchingCreator() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1", keys: ["著者値1"]),
            book(2, "作品タイトル2", keys: ["著者値2"]),
        ])
        #expect(out.isEmpty)
    }

    @Test("著者もサークルも取れていない本は候補にしない [SS-02]")
    func skipsBooksWithoutACreator() {
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1", keys: []),
            book(2, "作品タイトル2", keys: []),
        ])
        #expect(out.isEmpty)
    }

    @Test("検出は無視印を見ない——組んだ結果を出すかどうかは呼び出し側が決める [SS-05]")
    func detectionDoesNotLookAtTheIgnoreMark() {
        // 無視した 2 冊に 3 冊目が加わったら「状況が変わった」ことに気づける
        // ようにする——除いて組むと 3 冊目が 1 冊だけ残り、提案が消える。
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1", ignored: true),
            book(2, "作品タイトル2", ignored: true),
            book(3, "作品タイトル3"),
        ])
        #expect(out.count == 1)
        #expect(out[0].members.count == 3)
    }

    @Test("タイトルが全部同じなら重複であってシリーズではない [DU-01 の担当]",
          arguments: ["作品タイトル", "作品タイトル1"])
    func identicalTitlesAreNotASeries(title: String) {
        // **数字で終わるタイトルでも同じ**［code-review が見つけた穴］。
        // 接頭辞の長さで判定していたときは、後退で接頭辞が短くなるぶん
        // 「1 巻が 2 冊あるシリーズ」として通ってしまっていた。
        let out = SeriesSuggestionDetector.detect([book(1, title), book(2, title)])
        #expect(out.isEmpty)
    }

    @Test("タイトルが無い本は候補にしない（未整理はここに出さない）")
    func skipsBooksWithoutATitle() {
        let out = SeriesSuggestionDetector.detect([
            book(1, ""),
            book(2, ""),
        ])
        #expect(out.isEmpty)
    }

    // MARK: - グループの作り方

    @Test("グループ全体の共通接頭辞で判定する（隣り合う 2 冊だけを見ない）")
    func groupsUseTheWholeGroupPrefixNotTheAdjacentPair() {
        // 隣接ペアだけを見ると、接頭辞が**伸びていく**方向でも繋がってしまう
        // ——`作品タイトル12` と `作品タイトル123` は 8 文字を共有するが、
        // 1 冊目（7 文字）はそこまで届かない。グループ全体で見れば 6 文字
        // （数字の手前）に落ち着き、3 冊が 1 つの提案になる。
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1"),
            book(2, "作品タイトル12"),
            book(3, "作品タイトル123"),
        ])
        #expect(out.count == 1)
        #expect(out[0].seriesName == "作品タイトル")
        #expect(out[0].members.map(\.volume.number) == [1, 12, 123])
    }

    @Test("グループ全体の共通接頭辞で判定する（連鎖でグループが伸びない）")
    func groupsUseTheWholeGroupPrefix() {
        // 「作品タイトル1」と「作品タイトル2」は揃うが、
        // 「作品タイトルではない別の話」を足すと共通部分が「作品タイトル」まで
        // 縮み、境界（残りが空か数字）を満たさなくなる。
        let out = SeriesSuggestionDetector.detect([
            book(1, "作品タイトル1"),
            book(2, "作品タイトル2"),
            book(3, "作品タイトルではない別の話"),
        ])
        #expect(out.count == 1)
        #expect(out[0].members.map(\.id) == [FileID(rawValue: 1), FileID(rawValue: 2)])
    }

    @Test("1 冊が 2 つの提案に現れない（重なりは大きい方を採る）")
    func aBookAppearsInAtMostOneSuggestion() {
        // 著者で 3 冊、サークルで 2 冊のまとまりができる形。
        let out = SeriesSuggestionDetector.detect([
            book(1, "共通タイトル1", keys: ["著者値1", "サークル値A"]),
            book(2, "共通タイトル2", keys: ["著者値1"]),
            book(3, "共通タイトル3", keys: ["著者値1"]),
            book(4, "共通タイトル4", keys: ["サークル値A"]),
        ])
        let ids = out.flatMap { $0.members.map(\.id) }
        #expect(ids.count == Set(ids).count)
    }

    @Test("提案の並びは実行のたびに変わらない")
    func outputIsDeterministic() {
        let books = [
            book(1, "作品タイトル1", folder: "B"),
            book(2, "作品タイトル2", folder: "B"),
            book(3, "別作品タイトル1", folder: "A"),
            book(4, "別作品タイトル2", folder: "A"),
        ]
        let first = SeriesSuggestionDetector.detect(books)
        let again = SeriesSuggestionDetector.detect(books.reversed())
        #expect(first == again)
        #expect(first.map(\.folderPath) == ["A", "B"])
    }
}
