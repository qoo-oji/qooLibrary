//
//  ファイル保管庫の中と外を行き来するパスの組み立て [FA-02][FA-03]。
//
import Foundation

/// 保管庫（`.qooarchive`）の相対パスを組み立て・分解する純粋関数 [FA-02][FA-03]。
///
/// **「保管庫の中か」を判定する唯一の実装。** 走査（`.qooarchive` 配下を
/// `isArchived` として取り込む [SY-10]）・移動（保管庫へ／から）・整理
/// ウインドウ（元の場所の表示）が同じ規則を見る。**2 か所に持たないこと**
/// ——差分走査とフル走査で規則が食い違い、DB の中身が経路によって変わる、
/// という形の壊れ方を 2-2 で実際に踏んでいる。
///
/// ## 相対パスはライブラリルートからの相対
/// `managedFile.relativePath` と同じ座標系で扱う。`.qooarchive` は
/// **ライブラリフォルダ直下**にあり [FA-02]、その中はライブラリの階層を
/// そのまま写す [FA-03] ので、先頭の 1 成分を足す／取り除くだけで往復する。
public enum VaultPath {
    /// 保管庫フォルダの名前 [FA-02]。先頭が `.` なので Finder でもツリーでも
    /// 既定では隠れる [LP-08]（`FolderTreeNode` は `.skipsHiddenFiles`）。
    public static let folderName = ".qooarchive"

    private static let prefix = folderName + "/"

    /// この相対パスは保管庫の中か [SY-10]。
    ///
    /// **`.qooarchive` そのもの（末尾なし）は「中」ではない**——フォルダ自身は
    /// 蔵書の行を持たないので、判定に現れるのは必ず配下のパスになる。
    public static func isInside(_ relativePath: String) -> Bool {
        relativePath.hasPrefix(prefix)
    }

    /// 保管庫へ移したあとの相対パス。既に中にあるならそのまま返す。
    public static func archived(_ relativePath: String) -> String {
        isInside(relativePath) ? relativePath : prefix + relativePath
    }

    /// 保管庫から出したあとの相対パス。中に無ければ `nil`。
    ///
    /// **`archivedFromPath` [FA-04] が無いときの戻り先はこれで導く**——外部
    /// （Finder 等）で `.qooarchive` へ入れられたファイルは DB に元パスを
    /// 持たないが、FA-03 が「`.qooarchive` の階層を取り除くと元のパスと一致
    /// する」ことを保証しているので、記録が無くても戻せる。
    public static func original(_ relativePath: String) -> String? {
        guard isInside(relativePath) else { return nil }
        return String(relativePath.dropFirst(prefix.count))
    }
}
