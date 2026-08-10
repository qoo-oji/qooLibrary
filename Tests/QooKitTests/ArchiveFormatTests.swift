import Testing

@testable import QooKit

@Suite struct ArchiveFormatTests {
    @Test func recognizesStandardExtensions() {
        #expect(ArchiveFormat.from(fileExtension: "zip") == .zip)
        #expect(ArchiveFormat.from(fileExtension: "7z") == .sevenZip)
        #expect(ArchiveFormat.from(fileExtension: "rar") == .rar)
    }

    @Test func recognizesComicBookAliasExtensions() {
        #expect(ArchiveFormat.from(fileExtension: "cbz") == .zip)
        #expect(ArchiveFormat.from(fileExtension: "cb7") == .sevenZip)
        #expect(ArchiveFormat.from(fileExtension: "cbr") == .rar)
    }

    @Test func isCaseInsensitive() {
        #expect(ArchiveFormat.from(fileExtension: "ZIP") == .zip)
        #expect(ArchiveFormat.from(fileExtension: "CBR") == .rar)
    }

    @Test func unknownExtensionReturnsNil() {
        #expect(ArchiveFormat.from(fileExtension: "txt") == nil)
    }

    @Test func recognizesTarGzAsACompoundExtensionFromFilename() {
        #expect(ArchiveFormat.from(filename: "archive.tar.gz") == .tarGz)
        #expect(ArchiveFormat.from(filename: "archive.tgz") == .tarGz)
    }

    @Test func filenameLookupFallsBackToSimpleExtension() {
        #expect(ArchiveFormat.from(filename: "マンガ.cbz") == .zip)
    }
}
