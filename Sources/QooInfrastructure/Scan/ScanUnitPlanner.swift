//
//  差分スキャンの走査範囲を決める [SY-03][SY-12][FO-20]。
//
//  **FSEvents が報告したパスを、そのまま「読み直す場所」に翻訳する部分。**
//  ここを持たないと差分スキャンがライブラリ全体を列挙することになり、
//  ファイルが 1 つ変わるたびに 5 万件の走査が走る。
//
import Foundation
import QooKit

/// 1 回の差分スキャンで見る場所。
public enum ScanUnit: Sendable, Hashable {
    /// 列挙して DB と突き合わせる。`relativePath` が空ならライブラリ根。
    case enumerate(relativePath: String, recursive: Bool)
    /// **実体が確かに消えている**（`stat` が `ENOENT`）。列挙はせず、
    /// この配下の DB レコードを孤立にする [ID-06]。
    ///
    /// 消えたのがフォルダだった場合、その中身は親の「直下だけ」の照合では
    /// 拾えない——だから別の単位として持つ。**「読めなかった」ではなく
    /// 「確かに無い」と分かったときにだけ作ること**［F2 が最悪の失敗様式］。
    case vanished(relativePath: String)

    var relativePath: String {
        switch self {
        case .enumerate(let path, _), .vanished(let path): return path
        }
    }
}

/// 変更のあった相対パスから走査単位を導く。
///
/// ## なぜ「親を非再帰」と「自身を再帰」を使い分けるのか
/// FSEvents は `kFSEventStreamCreateFlagFileEvents` を指定してあるので**個々の
/// ファイル**を報告する。ただし**フォルダごと移動されてきた場合**（同一
/// ボリューム内の `rename`）は中のファイルが 1 つも作られないため、
/// **フォルダのパスが 1 件届くだけ**になる。その 1 件を「親を非再帰」で
/// 処理すると、中身が 1 件も DB に載らない。
///
/// | 届いたパスの実体 | 単位 | 理由 |
/// |---|---|---|
/// | ディレクトリ（存在する）| **自身を再帰** | 丸ごと移動されてきた可能性がある |
/// | ファイル（存在する）| 親を非再帰 | その 1 件だけ変わった |
/// | 何も無い（`ENOENT`）| 親を非再帰 ＋ **自身を `vanished`** | 消えたのがフォルダなら中身も孤立にする |
/// | 判定できない（権限・無応答）| 親を非再帰のみ | **推測で孤立にしない** |
public enum ScanUnitPlanner {

    /// パスの実体。呼び出し側が `FileIO` の中で解決して渡す [NV6-02]。
    public enum PathKind: Sendable, Equatable {
        case directory
        case file
        /// `stat` が `ENOENT` を返した＝**確かに無い**。
        case absent
        /// 権限・無応答などで判定できなかった。
        case unknown
    }

    /// - Returns: 走査単位。**`nil` は「フルスキャンへ落とせ」** [SY-04]。
    ///   空配列は「見るべき場所が無い」——走査対象外の変更しか届かなかった
    ///   ときで、フルスキャンへ落としてはならない。
    public static func units(changedPaths: [String],
                             kind: (String) -> PathKind,
                             limit: Int = AppLimits.Watch.maxIncrementalUnits) -> [ScanUnit]? {
        var enumerateUnits: Set<Unit> = []
        var vanished: Set<String> = []

        for raw in changedPaths {
            let path = normalize(raw)
            // 根そのものが動いた／根に対する変更は、範囲を絞る意味が無い。
            if path.isEmpty { return nil }
            // **列挙が到達しない場所は、差分でも見ない** [実機検証で発見]。
            //
            // `LibraryEnumerator` は隠し項目と `covers` を飛ばすが、差分の
            // 走査単位は**そこを起点に直接列挙する**ので、飛ばす規則が効かない。
            // 実際、`/Volumes/<ライブラリ>/.Trashes` に捨てた本や、検証用に
            // 置いた隠しフォルダの中身が蔵書として取り込まれた。
            // **フルスキャンなら決して現れない行**なので、次のフルスキャンで
            // 孤立になり、差分で戻り、を繰り返すことになる。
            if !isScannable(path) { continue }
            switch kind(path) {
            case .directory:
                enumerateUnits.insert(Unit(path: path, recursive: true))
            case .file, .unknown:
                enumerateUnits.insert(Unit(path: parent(of: path), recursive: false))
            case .absent:
                enumerateUnits.insert(Unit(path: parent(of: path), recursive: false))
                vanished.insert(path)
            }
        }

        // 根を再帰で見る単位が 1 つでもあれば、それはフルスキャンと同じ。
        if enumerateUnits.contains(where: { $0.path.isEmpty && $0.recursive }) { return nil }

        let pruned = prune(enumerateUnits)
        // `vanished` は、列挙する単位の再帰範囲に含まれるなら要らない
        // （その走査の孤立判定が同じ範囲を見るため）。
        let neededVanished = vanished.filter { path in
            !pruned.contains { $0.recursive && isAtOrUnder(path, $0.path) }
        }

        let total = pruned.count + neededVanished.count
        // **0 件は「フルスキャンへ落とせ」ではない。** 走査対象外の変更しか
        // 届かなかった場合で、そこで全体を列挙し直すのは明らかに過剰。
        if total == 0 { return [] }
        guard total <= limit else { return nil }

        var units = pruned.map { ScanUnit.enumerate(relativePath: $0.path, recursive: $0.recursive) }
        units += neededVanished.sorted().map { ScanUnit.vanished(relativePath: $0) }
        return units
    }

    // MARK: - 内部

    struct Unit: Hashable {
        let path: String
        let recursive: Bool
    }

    /// 祖先に再帰の単位があるものを落とし、同じパスの非再帰は再帰に吸収する。
    static func prune(_ units: Set<Unit>) -> [Unit] {
        let recursives = units.filter(\.recursive)
        var kept: [Unit] = []
        for unit in units {
            // 自分より上（自分自身は除く）に再帰の単位があれば要らない。
            if recursives.contains(where: { $0 != unit && isAtOrUnder(unit.path, $0.path) }) {
                continue
            }
            // 同じパスに再帰があるなら、非再帰の方は要らない。
            if !unit.recursive && recursives.contains(Unit(path: unit.path, recursive: true)) {
                continue
            }
            kept.append(unit)
        }
        // 順序を決定的にする（テストと診断ログのため）。
        return kept.sorted { ($0.path, $0.recursive ? 1 : 0) < ($1.path, $1.recursive ? 1 : 0) }
    }

    /// `LibraryEnumerator` が到達する場所か。
    ///
    /// 列挙の規則（隠し項目を飛ばす・`covers` へ降りない）をここでも同じく
    /// 適用する。**片方だけ直すと、差分とフルで DB の中身が食い違う。**
    static func isScannable(_ relativePath: String) -> Bool {
        for (index, component) in relativePath.split(separator: "/").enumerated() {
            // 保管庫は隠し名だが走査対象 [SY-10][FA2-12]。認めるのは
            // **ライブラリ根の直下の 1 つだけ** [FA-02] ——`LibraryEnumerator`
            // 側と同じ絞り方にする。片方だけ緩めると、差分では取り込まれるのに
            // フルスキャンでは孤立になる、という往復が起きる。
            if index == 0, component == VaultPath.folderName { continue }
            if component.hasPrefix(".") { return false }
            if component == "covers" { return false }
        }
        return true
    }

    /// 前後の `/` を落とす。`"."`・`""` はライブラリ根を表す。
    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p == "." ? "" : p
    }

    static func parent(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<index])
    }

    /// **素の `hasPrefix` では誤る** — `a/bc` が `a/b` の配下に見える。
    /// 区切りまで含めて確かめる（`MountTable` と同じ罠）。
    static func isAtOrUnder(_ path: String, _ ancestor: String) -> Bool {
        if ancestor.isEmpty { return true }
        if path == ancestor { return true }
        return path.hasPrefix(ancestor + "/")
    }
}
