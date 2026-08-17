import Foundation
import QooKit

/// エントリのパス検証 [EX-10〜EX-13]。libarchive・UnRAR 双方のバックエンドが
/// 同じ規則を共有するための純粋関数。
enum EntryPathValidation {
    struct ValidatedEntry {
        let relativePath: String
        let targetURL: URL
    }

    enum Outcome {
        case accepted(ValidatedEntry)
        case rejected(RejectionReason)
    }

    /// 検証に通れば展開先の絶対 URL を返す。通らなければ拒否理由を返す。
    static func validate(
        pathname: String,
        isDirectory: Bool,
        isSymlink: Bool,
        isSpecialEntry: Bool,
        followSymlinks: Bool,
        stagingRoot: URL
    ) -> Outcome {
        let name = pathname.hasSuffix("/") ? String(pathname.dropLast()) : pathname

        if name.isEmpty { return .rejected(.emptyName) }
        if name.hasPrefix("/") { return .rejected(.absolutePath) }
        // **バックスラッシュも区切りとして検査する**［フェーズ1完了時の監査で
        // 追加]。Windows 製のアーカイブは `..\..\evil` の形で格納され得て、
        // "/" だけを区切りに見ると単一の（奇妙だが合法な）ファイル名として
        // 素通りする。libarchive 経由では自前の書き込みなので実害は「変な名前の
        // ファイルができる」に留まるが、RAR は UnRAR 自身が書き込むため、
        // 区切りの解釈が UnRAR 側の変換に依存してしまう（CVE-2022-30333 と
        // 同系）。`..` をどちらの区切りでも持つ名前は正当なアーカイブには
        // まず現れないので、安全側に倒して拒否する。
        if name.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
            .contains("..") {
            return .rejected(.parentTraversal)
        }
        if name.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 0x20 && $0 != "\t") }) {
            return .rejected(.invalidCharacters)
        }
        if isSymlink && !followSymlinks { return .rejected(.symlinkSkipped) }
        if isSpecialEntry { return .rejected(.specialEntry) }

        // シンボリックリンクを辿る展開を許可した場合も、リンク先ではなく
        // 「このエントリ自身の展開先パス」がステージング配下に収まるかを見る
        // （リンク先の安全性はここでは扱わない — followSymlinks を有効にする
        // 呼び出し側の責務とする）。
        let stagingResolved = stagingRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = stagingResolved
            .appendingPathComponent(name)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let stagingPrefix = stagingResolved.path.hasSuffix("/") ? stagingResolved.path : stagingResolved.path + "/"
        guard candidate.path.hasPrefix(stagingPrefix) else {
            return .rejected(.escapesDestination)
        }

        return .accepted(ValidatedEntry(relativePath: name, targetURL: candidate))
    }
}
