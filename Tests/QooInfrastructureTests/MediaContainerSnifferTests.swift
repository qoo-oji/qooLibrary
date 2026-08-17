import Foundation
import QooKit
import Testing
import UniformTypeIdentifiers

@testable import QooInfrastructure

/// `MediaContainerSniffer` の検証。
///
/// **署名は実際に流通しているファイルの先頭バイト列を使う**（実機のライブラリで
/// 実測した Matroska の先頭 32 バイトをそのまま標本にしている）。1-15 の匿名化
/// テストで得た「きれいな作り物を標本にすると現実の入力を取りこぼす」という
/// 教訓を踏まえたもの。
struct MediaContainerSnifferTests {
    // MARK: - 純粋な判定

    /// 実機のライブラリにあった、`.mp4` を名乗る Matroska の実際の先頭バイト列。
    private static let realMatroskaHeader: [UInt8] = [
        0x1A, 0x45, 0xDF, 0xA3, 0xA3, 0x42, 0x86, 0x81,
        0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81,
        0x04, 0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x88,
        0x6D, 0x61, 0x74, 0x72, 0x6F, 0x73, 0x6B, 0x61, // "matroska"
    ]

    /// 実機のライブラリにあった、健全な mp4 の実際の先頭バイト列。
    private static let realISOBMFFHeader: [UInt8] = [
        0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, // size + "ftyp"
        0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00, // "isom"
    ]

    @Test func detectsMatroskaFromARealHeader() {
        #expect(MediaContainerSniffer.sniff(Self.realMatroskaHeader) == .matroska)
    }

    @Test func detectsISOBMFFFromARealHeader() {
        #expect(MediaContainerSniffer.sniff(Self.realISOBMFFHeader) == .isoBMFF)
    }

    @Test func detectsAVIOnlyWhenTheRIFFFormTypeSaysSo() {
        let avi = Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("AVI ".utf8)
        #expect(MediaContainerSniffer.sniff(avi) == .avi)
        // 同じ RIFF 署名を持つ音声（WAVE）を動画と誤認しないこと。
        let wave = Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WAVE".utf8)
        #expect(MediaContainerSniffer.sniff(wave) == nil)
    }

    @Test func detectsASFAndFLV() {
        #expect(MediaContainerSniffer.sniff([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66]) == .asf)
        #expect(MediaContainerSniffer.sniff(Array("FLV".utf8) + [0x01]) == .flv)
    }

    /// 短すぎる・空・無関係なバイト列で落ちず `nil` を返すこと
    /// （壊れたファイルや 0 バイトのファイルでもクラッシュしない）。
    @Test(arguments: [
        [UInt8](),
        [0x1A],
        [0x1A, 0x45],
        [0x1A, 0x45, 0xDF], // Matroska の署名の 1 バイト手前まで
        Array("RIFF".utf8), // フォームタイプに届かない
        [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79], // "ftyp" の 1 バイト手前まで
        Array("hello, this is not a video".utf8),
    ])
    func returnsNilForTruncatedOrUnrelatedBytes(bytes: [UInt8]) {
        #expect(MediaContainerSniffer.sniff(bytes) == nil)
    }

    // MARK: - 宣言し直すべき型

    @Test func declaresNothingWhenTheExtensionAlreadyMatches() {
        #expect(MediaContainer.matroska.contentTypeToDeclare(forFileNamed: "a.mkv") == nil)
        #expect(MediaContainer.matroska.contentTypeToDeclare(forFileNamed: "a.MKV") == nil)
        #expect(MediaContainer.matroska.contentTypeToDeclare(forFileNamed: "a.webm") == nil)
        #expect(MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "a.mp4") == nil)
        #expect(MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "a.mov") == nil)
    }

    /// 実体と拡張子が食い違うときは、**システムがその形式に割り当てている型**を
    /// 返すこと（識別子を決め打ちしない）。
    ///
    /// **判定に `mp4` を使うのが要点。** `public.mpeg-4` は macOS 標準の型なので
    /// どの環境でも具体型が引ける。`mkv` は**インストール済みアプリ次第**なので
    /// ここで使うと、開発機（Infuse 等が入っている）では通って、まっさらな CI で
    /// 落ちる／空振りする——実際に一度そうなった。CLAUDE.md に既記録の
    /// 「ルーティングの検証には OS 標準搭載の拡張子を使う」の再確認。
    @Test func declaresTheSystemsOwnTypeWhenTheExtensionDisagrees() throws {
        // 実体は mp4 なのに .mkv を名乗っている、という逆向きの食い違い。
        let declared = MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "video.mkv")
        let expected = try #require(UTType(filenameExtension: "mp4"))
        #expect(declared == expected)
        #expect(declared?.identifier == "public.mpeg-4")
        #expect(declared?.conforms(to: .movie) == true)
    }

    @Test func declaresTheSystemsTypeForAnExtensionlessName() throws {
        // 拡張子が無い場合も「食い違い」なので宣言の対象になる（拡張子から
        // UTI を決められないため、宣言しないと必ず失敗する）。
        let declared = MediaContainer.isoBMFF.contentTypeToDeclare(forFileNamed: "video")
        let expected = try #require(UTType(filenameExtension: "mp4"))
        #expect(declared == expected)
    }

    /// mkv の宣言は環境に依存するが、**どちらに転んでも契約は同じ**であること。
    ///
    /// 具体型があるなら「それを返す・`.movie` に準拠する・動的型ではない」、
    /// 無いなら「宣言しない」。どの分岐でも必ず何かを主張するので、環境が
    /// 変わっても空振りしない。
    @Test func matroskaDeclarationFollowsWhatTheSystemKnows() {
        let declared = MediaContainer.matroska.contentTypeToDeclare(forFileNamed: "video.mp4")
        let systemType = UTType(filenameExtension: "mkv")
        if let declared {
            #expect(declared == systemType)
            #expect(declared.conforms(to: .movie))
            #expect(!declared.identifier.hasPrefix("dyn."))
        } else {
            // mkv を扱うアプリが 1 つも無い環境（CI がこれ）。合成された動的型は
            // `.movie` に準拠しないので宣言の対象にならない。
            #expect(systemType?.conforms(to: .movie) != true)
        }
    }

    /// **`UTType(filenameExtension:)` は未知の拡張子でも `nil` を返さない**
    /// ——`dyn.…` の動的型を合成して返す（実測。CI では `mkv` がこれになり、
    /// 「引けなければ nil」という誤った前提で書いたテストが落ちて発覚した）。
    ///
    /// `contentTypeToDeclare` が動的型を弾けるのは `conforms(to: .movie)` の
    /// ガードのおかげである。**この前提が崩れたら気づけるように固定しておく**
    /// （`SystemSoundEffectTests` が OS 側の音源の実在を見張っているのと同じ趣旨）。
    @Test func unknownExtensionsYieldADynamicTypeThatIsNotAMovie() throws {
        let synthesized = try #require(UTType(filenameExtension: "zzzznotarealextension"))
        #expect(synthesized.identifier.hasPrefix("dyn."))
        #expect(!synthesized.conforms(to: .movie))
    }

    /// 上の動的型を**実際に弾いている**こと。手元の機では mkv も具体型に
    /// 解決されるため、この経路は存在しない拡張子を直接渡さないと通らない
    /// （それをしないと、CI を救っている当のガードが無検証のまま残る）。
    @Test func doesNotDeclareASynthesizedDynamicType() {
        #expect(MediaContainer.concreteMovieType(forExtension: "zzzznotarealextension") == nil)
        // 対照: OS 標準搭載の拡張子はちゃんと引ける。
        #expect(MediaContainer.concreteMovieType(forExtension: "mp4")?.identifier == "public.mpeg-4")
    }

    // MARK: - 実ファイルからの判定

    @Test func sniffsFromDiskAndReportsTheMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 実機で踏んだ形そのもの: 中身は Matroska、名前は .mp4。
        let misnamed = directory.appendingPathComponent("misnamed.mp4")
        try Data(Self.realMatroskaHeader).write(to: misnamed)
        #expect(MediaContainerSniffer.sniffBlocking(at: misnamed) == .matroska)

        let honest = directory.appendingPathComponent("honest.mp4")
        try Data(Self.realISOBMFFHeader).write(to: honest)
        #expect(MediaContainerSniffer.sniffBlocking(at: honest) == .isoBMFF)
    }

    @Test func sniffBlockingReturnsNilForMissingAndEmptyFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("nope.mp4")
        #expect(MediaContainerSniffer.sniffBlocking(at: missing) == nil)

        let empty = directory.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        #expect(MediaContainerSniffer.sniffBlocking(at: empty) == nil)
    }
}
