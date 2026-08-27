//
//  ファイル保管庫への出し入れ [FA-01〜FA-16][FDA-01〜FDA-02]。
//
//  実ファイルを動かすのは `FileOperationService` だけ [FO-01][B-10]。ここが
//  決めるのは「どこへ運ぶか」「サイドカーも連れて行くか」「空になった
//  フォルダをどうするか」で、`FileOps/` に置いてあるのは B-10 の許可範囲に
//  収めるため（`SecureExtractor` と同じ）。
//
import Foundation
import QooKit

public enum FileVault {

    /// 1 件を運んだ結果。**`to` は予定ではなく実際の着地点**——衝突すると
    /// 連番が付く [FA-13] ので、DB へ書くのは必ずこちら。
    public struct Relocation: Sendable, Hashable {
        /// ライブラリ根からの相対パス（移動前）。
        public let from: String
        /// ライブラリ根からの相対パス（移動後）。
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// 1 件を `from` から `to` へ運ぶ。保管庫へ入れるのも出すのも同じ経路。
    ///
    /// **入れると出すを別々に書かない。** 違うのは行き先の組み立て方だけで、
    /// 中間フォルダの作成 [FA-09]・衝突の連番 [FA-13]・サイドカーの連動
    /// [FA-14][FA-15] はまったく同じ。2 つ書くと、片方だけ直して取り残す。
    ///
    /// - Note: 空フォルダの後始末 [FA-06][FA-08] はここではしない。一括で
    ///   運ぶときに 1 件ごとに親を辿り直すのは無駄なので、呼び出し側が
    ///   最後に `pruneEmptyFolders` を 1 回呼ぶ。
    public static func relocate(from: String, to: String, root: URL,
                                fileOps: FileOperationService) async throws -> Relocation {
        let source = root.appendingPathComponent(from)
        let targetParentRelative = (to as NSString).deletingLastPathComponent
        let targetParent = targetParentRelative.isEmpty
            ? root
            : root.appendingPathComponent(targetParentRelative)

        // 戻す先のフォルダが既に消えていれば作って戻す [FA-09]。保管庫へ
        // 入れるときの `.qooarchive/…` も同じ経路で作られる [FA-02]。
        try await ensureDirectory(at: targetParent, root: root, fileOps: fileOps)

        // サイドカーは**運ぶ前に**探す [FA-14]。運んだあとでは元の場所に
        // 対応する画像がまだあるとは限らない（親フォルダを片付けたあとなら
        // なおさら）。
        let sidecar = await SidecarCoverLocator.sidecarCover(for: source)

        let receipts = try await fileOps.move(
            [source], to: targetParent,
            options: OpOptions(conflictPolicy: .keepBoth))   // [FA-13]
        // `.keepBoth` はスキップしないので、受領書が無いのは中断されたときだけ
        // （`transfer` は取り消しを検知するとそこまでの分を返す [ER-16]）。
        guard let receipt = receipts.first else { throw CancellationError() }
        let landed = receipt.toURL

        if let sidecar {
            // **着地したファイル名に合わせて運ぶ。** 素の `.keepBoth` に任せると、
            // 本体が `作品 2.cbz` になったのにサイドカーは `作品.png` のままか、
            // 独立に採番されて `作品 3.png` になり、**名前で突き合わせる
            // `SidecarCoverLocator` から外れる**。連番が付いた稀な場合にだけ
            // 効く配慮だが、外れると「保管庫へ入れた本だけ絵が消える」形になる。
            let targetName = landed.deletingPathExtension().lastPathComponent
                + "." + sidecar.pathExtension
            try await moveSidecar(sidecar, into: targetParent, named: targetName, fileOps: fileOps)
        }

        let landedRelative = relativePath(of: landed, under: root) ?? to
        return Relocation(from: from, to: landedRelative)
    }

    /// 空になったフォルダを根の手前まで遡って片付ける [FA-06][FA-08][FA-16]。
    ///
    /// **隠しファイルしか残っていない場合も空とみなす** [FA-10]——`.DS_Store`
    /// が 1 つ残っただけで畳めないと、実際にはほとんど片付かない。
    ///
    /// - Parameter directories: 起点（運び元の親と、その `covers`）。
    public static func pruneEmptyFolders(_ directories: [URL], root: URL,
                                         fileOps: FileOperationService) async {
        let rootPath = root.standardizedFileURL.path
        // 深いものから畳む——`A/covers` を消してから `A` を見ないと、
        // `covers` が残っているせいで `A` が空にならない。
        //
        // **これは費用の話であって、正しさの話ではない**［変異検証で空振り］。
        // 削除に成功したら 1 つ上を待ち行列へ戻すので、浅いほうから見ても
        // 最後には同じところへ落ち着く——違うのは `readdir` の回数だけ。
        // 順序を逆にする変異は検出できないが、**通ることを理由に外さないこと。**
        var pending = Set(directories.map(\.standardizedFileURL.path))
        while let deepest = pending.max(by: { $0.count < $1.count }) {
            pending.remove(deepest)
            guard deepest != rootPath, deepest.hasPrefix(rootPath + "/") else { continue }
            let url = URL(fileURLWithPath: deepest)
            guard await isEffectivelyEmpty(url) else { continue }
            do {
                let outcome = try await fileOps.deletePermanently([url])
                guard !outcome.receipts.isEmpty else { continue }
            } catch {
                // 片付けは best-effort——残っても実害は「空のフォルダが残る」
                // だけで、運んだこと自体は成立している。
                Log.fileOps.warning("保管庫: 空フォルダを片付けられませんでした \(Log.path(url)): \(error.localizedDescription)")
                continue
            }
            // 1 つ上も空になったかもしれない。
            pending.insert(url.deletingLastPathComponent().standardizedFileURL.path)
        }
    }

    // MARK: - 内部

    /// 隠し**ファイル**しか無ければ空とみなす [FA-10]。
    ///
    /// **隠しフォルダは「空」に数えない**［レビューで発見］。要件が挙げるのは
    /// `.DS_Store` のような隠しファイルで、片付けの相手は「中身が無くなった
    /// フォルダ」である。素朴に名前の `.` だけで数えると、`.git` や
    /// **このアプリ自身が作る `.qoo-replace-backup-<uuid>`** [NV-92] を抱えた
    /// フォルダまで空と判定し、`deletePermanently` が**ゴミ箱を経由せずに
    /// 木ごと消す**——しかも `undo()` はフォルダを作り直すだけなので戻らない。
    ///
    /// 判定できないもの（読めない・種別が取れない）は**空とみなさない**
    /// ——誤って残しても「空のフォルダが 1 つ残る」だけだが、誤って消すと
    /// 取り返しがつかない。
    static func isEffectivelyEmpty(_ url: URL) async -> Bool {
        await FileIO.perform {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []) else { return false }
            return entries.allSatisfy { entry in
                guard entry.lastPathComponent.hasPrefix(".") else { return false }
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard let isDirectory = values?.isDirectory,
                      let isSymbolicLink = values?.isSymbolicLink else { return false }
                return !isDirectory && !isSymbolicLink
            }
        }
    }

    /// 中間フォルダを**根の側から 1 段ずつ**作る [FA-02][FA-09]。
    ///
    /// `FileOperationService.createDirectory` は**親が存在することを要求する**
    /// ——「新規フォルダ」が Finder と同じ衝突検出をするための意図的な仕様で、
    /// `withIntermediateDirectories` に任せていない。保管庫は階層をそのまま
    /// 写す [FA-03] ので `.qooarchive/作者A/…` のように 2 段以上まとめて
    /// 要ることがあり、足りない分を自分で数える必要がある。
    ///
    /// **`deletingLastPathComponent()` のループは根で必ず止める**——このコード
    /// ベースはパス走査の無限ループを 2 度踏んでいる。ここは「根より下に
    /// いる間だけ」という条件で、1 周ごとにパスが必ず短くなる。
    static func ensureDirectory(at url: URL, root: URL,
                                fileOps: FileOperationService) async throws {
        let rootPath = root.standardizedFileURL.path
        var missing: [URL] = []
        var current = url.standardizedFileURL
        while current.path != rootPath, current.path.hasPrefix(rootPath + "/") {
            let path = current.path
            let exists = await FileIO.perform {
                var isDirectory: ObjCBool = false
                let found = FileManager.default.fileExists(atPath: path,
                                                           isDirectory: &isDirectory)
                return found && isDirectory.boolValue
            }
            if exists { break }
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            _ = try await fileOps.createDirectory(at: directory)
        }
    }

    private static func moveSidecar(_ sidecar: URL, into parent: URL, named: String,
                                    fileOps: FileOperationService) async throws {
        let covers = parent.appendingPathComponent("covers", isDirectory: true)
        // `covers` は運び先の直下にしか作らないが、その運び先自体がまだ
        // 無いこともある（保管庫へ初めて入れるとき）。
        try await ensureDirectory(at: covers, root: parent.deletingLastPathComponent(),
                                  fileOps: fileOps)
        let coversRelative = covers
        let receipts = try await fileOps.move(
            [sidecar], to: coversRelative,
            options: OpOptions(conflictPolicy: .keepBoth))
        // 着地名が違えば改名して名前で突き合わせられるようにする。
        if let landed = receipts.first?.toURL, landed.lastPathComponent != named {
            _ = try? await fileOps.rename(landed, to: named)
        }
    }

    /// ライブラリ根からの相対パス。根の外なら `nil`。
    ///
    /// **`public`**——ライブラリ配下のフォルダを保管庫へ移す [FDA-03] 側が、
    /// 選んだ URL を DB と同じ座標系へ翻訳するのに要る。
    public static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        path.removeFirst(rootPath.count + 1)
        return path
    }
}
