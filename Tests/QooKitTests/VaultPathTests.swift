//
//  保管庫のパスの組み立て [FA-02][FA-03]。
//
import Testing
import QooKit

@Suite("保管庫のパス [FA-02][FA-03]")
struct VaultPathTests {

    @Test("保管庫の中かを先頭の成分で判定する")
    func detectsPathsInsideTheVault() {
        #expect(VaultPath.isInside(".qooarchive/A/x.cbz"))
        #expect(!VaultPath.isInside("A/x.cbz"))
        // フォルダ自身は「中」ではない——蔵書の行として現れない。
        #expect(!VaultPath.isInside(".qooarchive"))
        // **深い場所の同名フォルダは保管庫ではない** [FA-02]。ライブラリ根の
        // 直下にあるものだけが保管庫で、利用者が自分で置いた同名フォルダを
        // 巻き込んではならない。
        #expect(!VaultPath.isInside("A/.qooarchive/x.cbz"))
    }

    @Test("往復すると元のパスに戻る [FA-03]")
    func roundTripsThroughTheVault() {
        let original = "作者A/作品名A 第01巻.cbz"
        let archived = VaultPath.archived(original)
        #expect(archived == ".qooarchive/作者A/作品名A 第01巻.cbz")
        #expect(VaultPath.original(archived) == original)
    }

    @Test("根の直下のファイルも往復する")
    func roundTripsForFilesAtTheRoot() {
        #expect(VaultPath.archived("x.cbz") == ".qooarchive/x.cbz")
        #expect(VaultPath.original(".qooarchive/x.cbz") == "x.cbz")
    }

    @Test("既に中にあるものは二重に包まない")
    func doesNotNestTheVault() {
        #expect(VaultPath.archived(".qooarchive/A/x.cbz") == ".qooarchive/A/x.cbz")
    }

    @Test("中に無いものからは元のパスを導けない")
    func returnsNilForPathsOutsideTheVault() {
        #expect(VaultPath.original("A/x.cbz") == nil)
    }
}
