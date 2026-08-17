import Foundation
import QooKit
import UniformTypeIdentifiers

/// 動画ファイルの**実体のコンテナ形式**（拡張子ではなく先頭バイト列で判定）。
///
/// ## なぜ拡張子では足りないのか（実機のライブラリで踏んだ）
/// macOS は UTI を**拡張子から**決めるため、実体と拡張子が食い違うファイルは
/// 誤ったパーサへ渡されてサムネイルが作れない。ユーザーのライブラリの
/// 実測では、`.mp4` を名乗る**実体は Matroska** のファイルが 2 本あり、
/// どちらも `QLThumbnailErrorDomain code 102` で即座に失敗していた
/// （EBML を解析すると中身は健全な H.264 + AAC + 字幕、1920×1080）。
/// mkv を扱えるサムネイル拡張がインストールされているのに、UTI が
/// `public.mpeg-4` なので**そちらが呼ばれることすら無かった**。
///
/// この種のファイルはダウンロード元の付け間違いで普通に流通するため、
/// 「壊れている」のではなく「名前が間違っているだけ」として扱う。
///
/// ## 判定は 16 バイトで足りる
/// いずれの形式も先頭の署名だけで確定する（`avi` の判定に 12 バイト目まで
/// 要るのが最長）。**動画本体のデコードは一切行わない。**
public enum MediaContainer: Sendable, Equatable, CaseIterable {
    /// ISO Base Media File Format（mp4 / m4v / mov）。
    case isoBMFF
    /// Matroska/EBML（mkv / webm / mka）。webm も EBML なのでここに含まれる
    /// —— 区別するには DocType まで読む必要があるが、サムネイル生成の観点では
    /// 同じ拡張が両方を扱うため区別する利得が無い。
    case matroska
    /// RIFF/AVI。
    case avi
    /// Advanced Systems Format（wmv / asf）。
    case asf
    /// Flash Video。
    case flv

    /// この形式を素直に名乗る拡張子。**ここに含まれていれば宣言し直す必要はない。**
    public var matchingExtensions: Set<String> {
        switch self {
        case .isoBMFF: ["mp4", "m4v", "mov", "qt"]
        case .matroska: ["mkv", "webm", "mka", "mks"]
        case .avi: ["avi"]
        case .asf: ["wmv", "asf", "wma"]
        case .flv: ["flv", "f4v"]
        }
    }

    /// 「この形式はこの機で何という型か」をシステムへ尋ねるための代表拡張子。
    public var canonicalExtension: String {
        switch self {
        case .isoBMFF: "mp4"
        case .matroska: "mkv"
        case .avi: "avi"
        case .asf: "wmv"
        case .flv: "flv"
        }
    }

    /// 拡張子が実体と食い違うとき、QuickLook へ宣言し直すべき型
    /// （`QLThumbnailGenerator.Request.contentType` に渡す）。食い違って
    /// いなければ `nil` ——現状どおり拡張子任せでよい。
    ///
    /// ## 型を決め打ちしてはいけない（実測）
    /// `.mkv` の UTI は**インストール済みアプリ次第で変わる**。この開発機では
    /// Infuse が宣言した `com.firecore.fileformat.mkv` に解決され、
    /// `UTType("org.matroska.mkv")` は**存在しなかった**（nil）。そのため
    /// 識別子を書かず、`UTType(filenameExtension:)` でシステムに尋ねる。
    ///
    /// ## 汎用の上位型では通らない（実測）
    /// `public.movie` を渡しても `code 102` で失敗した。サムネイル拡張が
    /// 実際に登録した**具体型**でなければならない。
    ///
    /// この機での実測（`.mp4` を名乗る Matroska に対して）:
    ///
    /// | 渡した型 | 結果 |
    /// |---|---|
    /// | なし（拡張子任せ） | FAIL 102 |
    /// | `UTType(filenameExtension: "mkv")` | **OK 512×512** |
    /// | `public.movie` | FAIL 102 |
    ///
    /// 型が引けない（その形式を扱うアプリが 1 つも無い）場合も `nil` を返す
    /// ——宣言し直しても扱える拡張が無いので、現状の挙動のままでよい。
    public func contentTypeToDeclare(forFileNamed name: String) -> UTType? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !matchingExtensions.contains(ext) else { return nil }
        return Self.concreteMovieType(forExtension: canonicalExtension)
    }

    /// システムがこの拡張子に割り当てている**具体的な動画型**。無ければ `nil`。
    ///
    /// ## `UTType(filenameExtension:)` は未知の拡張子でも `nil` を返さない
    /// **`dyn.…` の動的型を合成して返す**（実測）。これを素通しすると、その形式を
    /// 扱えるアプリが 1 つも無い環境で「意味の無い型」を QuickLook へ宣言して
    /// しまう。`.movie` 準拠を要求することで動的型を弾いている——**この 1 行が、
    /// mkv を扱うアプリの無い環境（CI がそれ）で従来どおりの挙動を保っている。**
    ///
    /// `private` にしないのは、動的型になる状況を環境に依らず再現できないため
    /// （手元の機では mkv も具体型に解決される）。テストが存在しない拡張子を
    /// 直接渡してこのガードを確かめる。
    static func concreteMovieType(forExtension ext: String) -> UTType? {
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .movie) else {
            return nil
        }
        return type
    }
}

/// 先頭バイト列から ``MediaContainer`` を見分ける。
public enum MediaContainerSniffer {
    /// 判定に必要なバイト数だけを読む純粋関数。判定できなければ `nil`。
    public static func sniff(_ bytes: [UInt8]) -> MediaContainer? {
        // EBML（Matroska / WebM）。
        if starts(bytes, with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        // ISO BMFF は先頭がボックスサイズなので、種別はオフセット 4 から。
        if matches(bytes, at: 4, ascii: "ftyp") { return .isoBMFF }
        // RIFF は音声（WAVE）でも同じ署名なので、フォームタイプまで見る。
        if matches(bytes, at: 0, ascii: "RIFF"), matches(bytes, at: 8, ascii: "AVI ") { return .avi }
        // ASF ヘッダオブジェクトの GUID 先頭 4 バイト。
        if starts(bytes, with: [0x30, 0x26, 0xB2, 0x75]) { return .asf }
        if matches(bytes, at: 0, ascii: "FLV") { return .flv }
        return nil
    }

    /// - Note: **ブロッキング。`FileIO.perform` の中からのみ呼ぶ** [NV6-01]
    ///   ——応答しない共有の上のファイルだと `open`/`read` で待たされる。
    public static func sniffBlocking(at url: URL) -> MediaContainer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: AppLimits.Thumbnail.containerProbeBytes) else {
            return nil
        }
        return sniff([UInt8](data))
    }

    private static func starts(_ bytes: [UInt8], with signature: [UInt8]) -> Bool {
        guard bytes.count >= signature.count else { return false }
        return Array(bytes[0..<signature.count]) == signature
    }

    private static func matches(_ bytes: [UInt8], at offset: Int, ascii: String) -> Bool {
        let signature = Array(ascii.utf8)
        guard bytes.count >= offset + signature.count else { return false }
        return Array(bytes[offset..<(offset + signature.count)]) == signature
    }
}
