import Foundation
import Testing

@testable import QooInfrastructure

@Suite struct MatroskaDimensionReaderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoo-matroska-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 実際の mkv エンコーダは使わず、EBML の構造だけを手作業で組み立てた
    /// 最小限のフィクスチャ（`EBML header > Segment(サイズ不明) > Tracks >
    /// TrackEntry > (TrackType=video, Video > PixelWidth/PixelHeight)`）。
    private func makeMinimalMKV(width: UInt16, height: UInt16) -> Data {
        var bytes: [UInt8] = []

        // EBML header: ID + 1-byte size(4) + 4 bytes of don't-care content.
        bytes += [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x01, 0x02, 0x03, 0x04]

        // PixelWidth (ID 0xB0, size 2, big-endian value).
        let widthBytes: [UInt8] = [0xB0, 0x82, UInt8(width >> 8), UInt8(width & 0xFF)]
        // PixelHeight (ID 0xBA, size 2, big-endian value).
        let heightBytes: [UInt8] = [0xBA, 0x82, UInt8(height >> 8), UInt8(height & 0xFF)]
        let videoContent = widthBytes + heightBytes
        // Video (ID 0xE0, size = videoContent.count, assumed to fit in 1-byte VINT for this fixture).
        let videoBytes: [UInt8] = [0xE0, 0x80 | UInt8(videoContent.count)] + videoContent

        // TrackType (ID 0x83, size 1, value 1 = video).
        let trackTypeBytes: [UInt8] = [0x83, 0x81, 0x01]
        let trackEntryContent = trackTypeBytes + videoBytes
        // TrackEntry (ID 0xAE, size = trackEntryContent.count).
        let trackEntryBytes: [UInt8] = [0xAE, 0x80 | UInt8(trackEntryContent.count)] + trackEntryContent

        // Tracks (ID 0x16 0x54 0xAE 0x6B, size = trackEntryBytes.count).
        let tracksBytes: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x80 | UInt8(trackEntryBytes.count)] + trackEntryBytes

        // Segment (ID 0x18 0x53 0x80 0x67, unknown size = 0xFF for a 1-byte VINT).
        bytes += [0x18, 0x53, 0x80, 0x67, 0xFF]
        bytes += tracksBytes

        return Data(bytes)
    }

    @Test func readsPixelDimensionsFromAMinimalFixture() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.mkv")
        try makeMinimalMKV(width: 1920, height: 1080).write(to: url)

        let dimensions = MatroskaDimensionReader.dimensions(of: url)

        #expect(dimensions?.width == 1920)
        #expect(dimensions?.height == 1080)
    }

    @Test func readsUltrawideDimensions() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.mkv")
        try makeMinimalMKV(width: 1980, height: 808).write(to: url)

        let dimensions = MatroskaDimensionReader.dimensions(of: url)

        #expect(dimensions?.width == 1980)
        #expect(dimensions?.height == 808)
    }

    @Test func returnsNilForNonMKVFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.txt")
        try Data("plain text, not an mkv".utf8).write(to: url)

        #expect(MatroskaDimensionReader.dimensions(of: url) == nil)
    }

    @Test func returnsNilForTruncatedOrCorruptFile() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("truncated.mkv")
        // A valid-looking EBML header start but nothing else — must not crash.
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x84]).write(to: url)

        #expect(MatroskaDimensionReader.dimensions(of: url) == nil)
    }

    @Test func returnsNilWhenNoVideoTrackIsPresent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio-only.mkv")

        // Same structure but TrackType = 2 (audio), no Video element.
        var bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x01, 0x02, 0x03, 0x04]
        let trackTypeBytes: [UInt8] = [0x83, 0x81, 0x02] // audio
        let trackEntryBytes: [UInt8] = [0xAE, 0x80 | UInt8(trackTypeBytes.count)] + trackTypeBytes
        let tracksBytes: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x80 | UInt8(trackEntryBytes.count)] + trackEntryBytes
        bytes += [0x18, 0x53, 0x80, 0x67, 0xFF]
        bytes += tracksBytes
        try Data(bytes).write(to: url)

        #expect(MatroskaDimensionReader.dimensions(of: url) == nil)
    }
}
