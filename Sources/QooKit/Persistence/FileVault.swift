//
//  ファイル保管庫の一覧と出入りの記録 [FA-04][FA-05][FAW-01〜FAW-05]。
//
import Foundation

/// 保管庫にあるファイル 1 件 [FAW-01]。
///
/// **フォルダごと移した場合もファイル単位で扱う** [FDA-05]——`.qooarchive` の
/// 中は元の階層をそのまま写している [FA-03] ので、「どのフォルダから来たか」は
/// パスから読める。フォルダという単位を別に持たない。
public struct ArchivedFile: Sendable, Hashable, Identifiable {
    public let row: FileRow
    /// ラベル紐づけの件数。削除の確認で「何件のラベルが外れるか」を見せる
    /// [LE-08 と同じ考え方]。`manuallyRemoved` は数えない。
    public let labelCount: Int

    public var id: FileID { row.id }
    /// 移す前の相対パス [FA-04]。外部（Finder 等）で `.qooarchive` へ入れられた
    /// ものは記録が無いので `nil`——そのときの戻り先は `VaultPath.original` が
    /// 現在のパスから導く [FA-03]。
    public var archivedFromPath: String? { row.archivedFromPath }
    /// 保管した日時 [FAW-05]。記録が無ければ `nil`。
    public var archivedAt: Date? { row.archivedAt }

    /// 一覧を束ねる見出し——元のフォルダ [15.4 節「元フォルダごとに整理」]。
    /// 記録があればそれを、無ければ現在のパスから導いたものを使う。
    public var originalFolder: String {
        let path = archivedFromPath ?? VaultPath.original(row.relativePath) ?? row.relativePath
        let parent = (path as NSString).deletingLastPathComponent
        return parent
    }

    public init(row: FileRow, labelCount: Int) {
        self.row = row
        self.labelCount = labelCount
    }
}

/// 保管庫の出入り 1 件分の記録 [FA-04]。
///
/// **実ファイルを動かしたあとに DB へ書く**。`relativePath` は移動先の
/// 受領書（`OpReceipt.toURL`）から作る——衝突で連番が付く [FA-13] ことが
/// あるので、こちらで組み立てた予定のパスを書いてはならない。
public struct VaultMove: Sendable, Hashable {
    public let id: FileID
    /// 移動後の相対パス（ライブラリ根から）。
    public let relativePath: String
    /// 移動前の相対パス。保管庫へ**入れる**ときだけ `archivedFromPath` になる。
    public let previousPath: String
    /// 保管庫へ入れた日時 [FAW-05]。**1 件ごとに持つ**——⌘Z で「戻す」を
    /// 取り消したときに**元の日時へ戻す**ため。バッチ共通の「今」を書くと、
    /// 取り消すたびに日時が変わり、日時での並べ替えが実態とずれる。
    public let archivedAt: Date

    public init(id: FileID, relativePath: String, previousPath: String,
                archivedAt: Date = Date()) {
        self.id = id
        self.relativePath = relativePath
        self.previousPath = previousPath
        self.archivedAt = archivedAt
    }
}
