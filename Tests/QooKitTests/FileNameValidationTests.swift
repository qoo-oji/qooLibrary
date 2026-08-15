import Foundation
import Testing

@testable import QooKit

/// 名前の検証。**何を禁止するかは実測で決めた**ので、この suite は
/// その実測結果を固定するためのもの。
///
/// macOS がマウントし得る形式すべて（APFS / APFS 大文字小文字区別 / HFS+ /
/// HFS+ 大文字小文字区別 / exFAT / FAT12・16・32 / UDF / SMB〈実 NAS〉）で
/// 同じ名前を作って確かめたところ、**どの形式でも拒否されたのは `/` と
/// `.` と `..` だけ**だった。Windows で禁止されている文字も、改行・タブ・
/// 制御文字も、末尾の空白・ドットも、すべての形式が受け付けた。
///
/// したがって「Windows で禁止だから」という理由で文字を増やしてはいけない。
/// 実際には作れる名前を理由なく拒むことになる。
@Suite struct FileNameValidationTests {
    // MARK: - 拒否すべきもの

    /// この 1 件がこの型を作った理由。`/` を含む名前をそのまま
    /// `appendingPathComponent` へ渡すと、リネームのつもりが**別フォルダへの
    /// 移動**になる（実測で再現）。ユーザーから見ると「名前を変えたはずの
    /// ファイルが一覧から消える」。
    @Test func rejectsPathSeparator() {
        #expect(throws: FileNameValidation.Failure.forbiddenCharacter("/")) {
            try FileNameValidation.sanitized("親/子.cbz")
        }
        // 先頭・末尾でも同じ。
        #expect(!FileNameValidation.isAcceptable("/absolute"))
        #expect(!FileNameValidation.isAcceptable("trailing/"))
    }

    @Test func rejectsEmptyAndWhitespaceOnly() {
        #expect(throws: FileNameValidation.Failure.empty) { try FileNameValidation.sanitized("") }
        #expect(throws: FileNameValidation.Failure.empty) { try FileNameValidation.sanitized("   ") }
        #expect(throws: FileNameValidation.Failure.empty) { try FileNameValidation.sanitized("\n\t") }
    }

    @Test func rejectsReservedDotNames() {
        #expect(throws: FileNameValidation.Failure.reservedDotName) { try FileNameValidation.sanitized(".") }
        #expect(throws: FileNameValidation.Failure.reservedDotName) { try FileNameValidation.sanitized("..") }
    }

    // MARK: - 通すべきもの（誤って拒否する退行を捕まえる）

    /// **Windows で禁止されている文字は macOS では通る。** 実測で APFS /
    /// HFS+ / exFAT / FAT / UDF / SMB のすべてが受け付けた。ここを禁止すると
    /// 正当な名前が付けられなくなる。
    @Test(arguments: ["a:b", "a\\b", "a*b", "a?b", "a\"b", "a<b>c", "a|b"])
    func acceptsCharactersThatOnlyWindowsForbids(_ name: String) {
        #expect(FileNameValidation.isAcceptable(name), "\(name) を誤って拒否した")
    }

    /// 先頭ドット・末尾ドット・末尾空白も実測ではすべて通る。
    /// 末尾空白は前後の空白除去で落ちるため、内側に空白を持つ形で確かめる。
    @Test func acceptsDotPrefixedAndSpacedNames() {
        #expect(FileNameValidation.isAcceptable(".hidden"))
        #expect(FileNameValidation.isAcceptable("名前."))
        #expect(FileNameValidation.isAcceptable("作品名 第01巻.cbz"))
    }

    /// **この分野で実際に使われる形の名前**を標本にする。
    /// きれいな例だけで固めると、いちばん普通の入力を取りこぼす
    /// （1-15 の匿名化テストで実際に踏んだ教訓）。
    @Test(arguments: [
        "(成年コミック) [98765架空社] 作品名 第01巻.cbz",
        "【C99】作品名 → 続編、その2「完全版」 (1:2).cbz",
        "🐈ねこまんが 第03巻.cbz",
    ])
    func acceptsRealisticLibraryNames(_ name: String) {
        #expect(FileNameValidation.isAcceptable(name), "\(name) を誤って拒否した")
    }

    /// 前後の空白は落とす（Finder も落とす）が、中身は変えない。
    @Test func trimsSurroundingWhitespaceOnly() throws {
        #expect(try FileNameValidation.sanitized("  作品名.cbz  ") == "作品名.cbz")
        #expect(try FileNameValidation.sanitized("a b c") == "a b c")
    }

    // MARK: - 長さ

    /// 上限の単位は「NFD 正規化後の UTF-16 単位」。**バイト数ではない。**
    ///
    /// バイト数で 255 にすると、日本語 86 文字（258 バイト）で弾かれる。
    /// 実測では APFS/HFS+ は「あ」を 255 個まで受け付けた（765 バイト）ので、
    /// バイト基準は**実際には作れる名前を拒む**ことになる。
    @Test func lengthLimitIsCountedInDecomposedUTF16Units() throws {
        let ascii255 = String(repeating: "a", count: 255)
        #expect(FileNameValidation.isAcceptable(ascii255))
        #expect(!FileNameValidation.isAcceptable(ascii255 + "a"))

        // 765 バイトだが 255 単位なので通る（バイト基準なら誤って弾かれる）。
        let hiragana255 = String(repeating: "あ", count: 255)
        #expect(hiragana255.utf8.count == 765)
        #expect(FileNameValidation.isAcceptable(hiragana255), "日本語の長い名前を誤って拒否した")

        // 濁点は NFD で 2 単位になるため、実測どおり 127 個までが上限。
        #expect(FileNameValidation.isAcceptable(String(repeating: "が", count: 127)))
        #expect(!FileNameValidation.isAcceptable(String(repeating: "が", count: 128)))
    }

    // MARK: - 文言 [ER-03]

    /// 「エラーN」形式の既定文言へ戻る退行を捕まえる。文言そのものより
    /// **原因を名指しできているか**を見ている。
    @Test func everyFailureExplainsItself() {
        let failures: [FileNameValidation.Failure] = [
            .empty, .forbiddenCharacter("/"), .reservedDotName, .tooLong(units: 300),
        ]
        for failure in failures {
            let message = failure.localizedDescription
            #expect(!message.contains("FileNameValidation"), "型名が出ている: \(message)")
            #expect(!message.isEmpty)
        }
        // 使えない文字は、どの文字が問題なのかを示す。
        #expect(FileNameValidation.Failure.forbiddenCharacter("/").localizedDescription.contains("/"))
    }
}
