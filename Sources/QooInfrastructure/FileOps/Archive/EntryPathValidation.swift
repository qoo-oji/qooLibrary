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
        if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
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
