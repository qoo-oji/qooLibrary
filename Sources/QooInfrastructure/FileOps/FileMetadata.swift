import Foundation
import QooKit

/// `stat(2)` とボリューム UUID から、ファイルの識別子 [ID-01] と
/// 「内容の版」[`FileContentStamp`] を取り出す共通ヘルパー。
///
/// 以前は `FileOperationService`・`ThumbnailService`・`QuickLookCoverStore`
/// がそれぞれ同じ数行を持っていた（「切り出すほどの規模ではない」という
/// 判断だった）。キャッシュの鍵に更新日時とサイズを足す際、3 箇所とも
/// 直す必要が生じて**同じ計算が食い違う余地**が現実の問題になったため、
/// ここへ一本化した。
///
/// 読み取りのみで `FileManager` の変更系 API を使わないため B-10 の対象では
/// ないが、`FileOperationService` と対で読まれるものなので同じ場所に置く。
enum FileMetadata {
    /// 「どのファイルか」[ID-01]。中身が変わっても改名されても不変。
    static func identity(of url: URL) throws -> FileIdentity {
        try stamp(of: url).identity
    }

    /// 「どのファイルの、どの内容か」。キャッシュの鍵に使う
    /// [`FileContentStamp` のコメント参照]。
    static func stamp(of url: URL) throws -> FileContentStamp {
        let volumeUUID = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString ?? ""
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileContentStamp(
            identity: FileIdentity(volumeUUID: volumeUUID, inode: UInt64(info.st_ino)),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }
}
