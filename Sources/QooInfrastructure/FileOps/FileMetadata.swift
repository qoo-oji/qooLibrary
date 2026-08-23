import Foundation

/// クラウド上にしか実体が無いファイル（iCloud Drive の「ストレージを最適化」で
/// ローカルから追い出されたもの）を見分ける。
///
/// ## 実測で分かったこと
/// `~/Library/Mobile Documents` 上のファイルを `evictUbiquitousItem` で
/// 追い出すと `st_flags` に `SF_DATALESS` が立ち、`totalFileAllocatedSize` は
/// **0** になる（`fileSize` は満額のまま）。この状態で読み取ると:
///
/// | 読み方 | 結果 |
/// |---|---|
/// | 素の `Data(contentsOf:)`（協調なし） | **成功**。ただし約 1 秒かかる（その場でダウンロード）|
/// | `FileHandle` で先頭だけ読む | **成功**。同じく約 1 秒 |
/// | `NSFileCoordinator` 経由 | 成功。**協調なしと差が無かった** |
///
/// つまり**読めなくなるわけでも、固まるわけでもない**。当初は
/// 「協調読み取りをしていないので失敗・ハングする」と疑っていたが、
/// 実測で否定された（`NSFileCoordinator` の導入も不要と判断した根拠）。
///
/// **本当の問題は別**: 1 件あたり約 1 秒かけて**実際にダウンロードが走る**こと。
/// サムネイルは一覧を表示しただけで自動的に何百件も生成されるため、
/// クラウドに預けたライブラリを開くと、ユーザーが頼んでもいないのに
/// 蔵書全体のダウンロードが始まってしまう。Finder も追い出されたファイルの
/// サムネイルは作らず、雲のバッジ付きの汎用アイコンを見せる。
public enum CloudMaterialization {
    /// 実体がローカルに無いか。判定できなければ `false`（＝ふつうのファイルとして扱う）。
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
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

    /// ボリューム識別子が分かっている場合の版。**走査のホットパス用** [PF-13]。
    ///
    /// 1 ライブラリの全ファイルは同じボリュームにあるので、識別子はライブラリ
    /// ごとに 1 回求めれば足りる。1 件ごとに `VolumeIdentity.identifier(for:)`
    /// （`statfs` を伴う）を呼ぶと 5 万件で無駄が積み上がる。
    ///
    /// - Note: ライブラリの内側に別ボリュームがマウントされている場合は
    ///   inode が衝突しうるが、3.2 節はライブラリを 1 ボリューム前提としている。
    static func identity(of url: URL, volumeUUID: String) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(volumeUUID: volumeUUID, inode: UInt64(info.st_ino))
    }

    /// 「どのファイルの、どの内容か」。キャッシュの鍵に使う
    /// [`FileContentStamp` のコメント参照]。
    static func stamp(of url: URL) throws -> FileContentStamp {
        // **`?? ""` にしてはならない** [NV3-01]。SMB では `volumeUUIDString` が
        // 必ず nil になるため、空文字で埋めると**マウント中のネットワーク共有
        // すべてが同じボリュームに見え**、別のファイルどうしが同じ
        // `FileIdentity` になる（結果として別の作品の表紙が表示される）。
        // 取れなければマウント元から導く（`VolumeIdentity`）。
        guard let volumeUUID = VolumeIdentity.identifier(for: url) else {
            throw CocoaError(.fileReadUnknown)
        }
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

/// ライブラリの DB 行を引くための識別子 [ID-01][ID-02]。
///
/// `FileMetadata` は `QooInfrastructure` の内部型なので、上位層（インスペクタが
/// 選択中のファイルの行を引く等）から使えるようにする窓口をここに置く。
///
/// **`library.volumeUUID` を渡すこと。** 走査が
/// `FileMetadata.identity(of:volumeUUID:)` に**ライブラリの**識別子を渡して
/// 書いたのと同じ組でなければ引き当たらない——ここで
/// `VolumeIdentity.identifier(for: url)` を独立に求め直すと、走査時と食い違った
/// 場合に「DB に載っているのに引けない」という、原因の分かりにくい形になる。
public enum LibraryFileIdentity {
    /// - Note: `stat(2)` を伴う。**`FileIO.perform` の中から呼ぶこと** [NV6-02]。
    public static func of(_ url: URL, volumeUUID: String) -> FileIdentity? {
        FileMetadata.identity(of: url, volumeUUID: volumeUUID)
    }
}
