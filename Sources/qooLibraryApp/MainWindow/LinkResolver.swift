import Foundation

/// シンボリックリンク・Finder エイリアスを、**開くときだけ**リンク先へ
/// 解決する [SL-02]。
///
/// ## 追跡しない、という原則との関係
/// [SL-01] は「リンクは追跡せず、リンク自体を 1 つの項目として表示する」。
/// 一覧・コピー・スキャンはすべてその原則どおりで、ここで解決するのは
/// **ダブルクリック／Enter で「開く」ときの行き先だけ**（SL-02 が言う
/// 「表示上の追従のみ」）。Finder と同じ体験になる。
///
/// ツリーの展開はリンクを辿らない [SL-05]（無限ループを防ぐため）ので、
/// ここは呼ばれない。
///
/// ## 呼び出しはメインスレッドから行わない [NV6-02]
/// `readlink(2)` とブックマーク解決はどちらも I/O で、リンク先が応答しない
/// ネットワーク上にあれば戻ってこない。`FileIO.perform` の中から呼ぶこと。
enum LinkResolver {
    struct Resolved: Sendable {
        let url: URL
        let isDirectory: Bool
        /// Finder が 1 つの項目として扱うディレクトリ（`.app` など）。
        let isPackage: Bool

        /// **フォルダとして中へ入るか。** パッケージは「開く＝起動する」もの
        /// なので偽 [ユーザー要望、`FolderEntry.isNavigableFolder` と同じ判断]。
        var isNavigableFolder: Bool { isDirectory && !isPackage }
    }

    /// リンクなら解決した先を、そうでなければそのまま返す。
    ///
    /// 解決できない場合（リンク切れ、権限が無い、エイリアスの参照先が
    /// 消えている）は**元の URL のまま返す** — その方が、後続の「開く」処理が
    /// 出す標準のエラーでユーザーに事情が伝わる。ここで独自のエラーを
    /// 作っても情報が増えない。
    static func resolve(_ url: URL) -> Resolved {
        let target = resolvedTarget(of: url) ?? url
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return Resolved(
            url: target,
            isDirectory: values?.isDirectory ?? false,
            isPackage: values?.isPackage ?? false
        )
    }

    private static func resolvedTarget(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isSymbolicLink == true {
            // `resolvingSymlinksInPath()` は使わない — 先頭の `/private` を
            // 剥がす特別扱いがあり、実体と違うパスになることがある
            // （`DirectoryChangeHub.physicalPath` で踏んだのと同じ罠）。
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return nil
            }
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
            return target.standardizedFileURL
        }
        // Finder エイリアスはブックマークとして解決する。**`isAliasFileKey` は
        // シンボリックリンクにも `true` を返す**ため、必ずリンク判定の後で見る。
        if values?.isAliasFile == true {
            return try? URL(resolvingAliasFileAt: url, options: [.withoutUI])
        }
        return nil
    }
}
