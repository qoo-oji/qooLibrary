import Foundation

/// **いまマウントされているボリュームの一覧**を、ファイルシステムに一切
/// 触れずに答える [NV6-02][NV-93]。
///
/// ## なぜ専用の型が要るのか
/// 「この場所はネットワークか」「このボリュームはまだ繋がっているか」は、
/// 素直に書くと `URL.resourceValues(forKeys:)` や `statfs(path)` になる。
/// どちらも**その場所のファイルシステムへ問い合わせる**ので、相手が応答
/// しなければ戻ってこない——SMB なら最大 30 秒、NFS の hard マウント（既定）
/// なら無限（8章 §8.11.6）。**判定したい当の状況（切断）で、判定そのものが
/// 固まる**という筋の悪さがある。
///
/// `getmntinfo_r_np(&buf, MNT_NOWAIT)` はカーネルが持つマウント表を
/// そのまま写して返すだけで、**どのファイルシステムにも問い合わせない**。
/// man page が `MNT_NOWAIT` について「ファイルシステムへ更新を要求せず、
/// 手元にある情報を返す」と明記している通りで、**`MNT_WAIT` を渡しては
/// ならない**（そちらは各ファイルシステムに `statfs` を要求するため、
/// この型の存在理由がそのまま消える）。
///
/// | | 問い合わせ先 | 切断時 |
/// |---|---|---|
/// | `url.resourceValues([.volumeIsLocalKey])` | **そのボリューム** | **ブロックし得る** |
/// | `statfs(path)` | **そのボリューム** | **ブロックし得る** |
/// | `getmntinfo_r_np(MNT_NOWAIT)` | カーネルのマウント表のみ | **ブロックしない** |
///
/// したがって**この型はメインアクタから呼んでよい**——`FileIO` へ逃がす
/// 必要のある数少ない例外である。
///
/// ## 費用 [実測]
/// マウント表 97 件（Time Machine のスナップショットが並んだ状態）で
/// **1 回 0.13 ms**。1 回の判定ごとに読み直しても差し支えないが、
/// **同じ判定を何十回も繰り返す場面では ``current()`` を 1 回だけ呼んで
/// 使い回すこと** — スナップショットを渡し回せるよう値型にしてある。
///
/// ## `MNT_LOCAL` は信用してよいのか [実測]
/// 本プロジェクトは能力フラグに繰り返し裏切られている（`volumeIsEjectable`、
/// `supportsPersistentIDs`、`supportsExclusiveRenaming`）ので、ここでも
/// 鵜呑みにせず実測した。この機に実在する 9 ボリューム（APFS 起動・
/// 外付け APFS 2 本・**SMB**・UDF・devfs・ディスクイメージ 3 本）すべてで
/// **`MNT_LOCAL` と `URLResourceKey.volumeIsLocalKey` の答えが一致した**。
///
/// ただし NV-80 の原則どおり、**これを「できる証明」には使わない**。
/// ここでの用途は「ポーリングを足すか」「退避してよいか」を決めるだけで、
/// 取り違えても安全側に倒れる judgement に限っている。
///
/// - Note: File Provider（iCloud 等）は**ローカルと答える**（8章 §8.11.1）。
///   これはこの型の欠陥ではなく macOS の申告どおりで、クラウドの判定は
///   ``CloudSyncLocation`` の担当である。
public struct MountTable: Sendable {

    /// マウント 1 件分。必要になった項目だけを写している。
    public struct Entry: Sendable, Equatable {
        /// マウント先（`f_mntonname`）。例: `/`、`/Volumes/Private`。
        public let mountPoint: String
        /// ファイルシステム種別（`f_fstypename`）。例: `apfs`、`smbfs`。
        public let fileSystemType: String
        /// `MNT_LOCAL` が立っているか。ネットワーク越しなら `false`。
        public let isLocal: Bool
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// いまのマウント表を写し取る。**ファイルシステムには触れない。**
    public static func current() -> MountTable {
        var buffer: UnsafeMutablePointer<statfs>?
        // `getmntinfo` ではなく `_r_np` 版を使う。前者は**プロセス共有の
        // 静的バッファ**を返すので、別スレッドが同時に呼ぶと互いの結果を
        // 壊す。こちらは呼び出し側が `free` する新しい領域を返す。
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return MountTable(entries: []) }
        defer { free(buffer) }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var raw = buffer[index]
            entries.append(
                Entry(
                    mountPoint: Self.string(from: &raw.f_mntonname),
                    fileSystemType: Self.string(from: &raw.f_fstypename),
                    isLocal: raw.f_flags & UInt32(MNT_LOCAL) != 0
                )
            )
        }
        return MountTable(entries: entries)
    }

    // MARK: - 問い合わせ

    /// `path` を含むマウントのうち、**もっとも深いもの**。
    ///
    /// マウントは入れ子になる（`/` の中に `/Volumes/…`、その中にさらに
    /// ディスクイメージ）ので、**最長一致でなければ必ず間違える** —
    /// `/` は他のすべての接頭辞なので、単なる前方一致では何もかもが
    /// 起動ボリューム扱いになる。
    public func entry(containing path: String) -> Entry? {
        let target = Self.normalized(path)
        var best: Entry?
        for entry in entries {
            guard Self.path(target, isAtOrUnder: entry.mountPoint) else { continue }
            if best == nil || entry.mountPoint.count > best!.mountPoint.count {
                best = entry
            }
        }
        return best
    }

    /// この場所がネットワーク越しか。
    ///
    /// **判定できなければ `false`（ローカル扱い）に倒す。** 呼び出し側は
    /// どちらもこの向きが安全になるよう作ってある——ポーリングを足しそこねても
    /// FSEvents と前面復帰時の再同期が残り、退避しそこねても実害は無い。
    public func isRemote(path: String) -> Bool {
        guard let entry = entry(containing: path) else { return false }
        return !entry.isLocal
    }

    /// ``isRemote(path:)`` の `URL` 版。
    public func isRemote(_ url: URL) -> Bool {
        isRemote(path: url.standardizedFileURL.path)
    }

    /// `url` が、いま繋がっていないボリューム上を指しているか [NV-93]。
    ///
    /// **``entry(containing:)`` で判定してはいけない**［最初にそう書いて
    /// テストに落とされた］。ボリュームが外れると、その配下のパスは
    /// どのマウントにも一致しなくなり**最長一致が `/` まで後退する**。
    /// `/` は当然マウントされているので、外れた直後こそ「繋がっている」と
    /// 答えてしまう——**知りたい状況でだけ逆を答える**という最悪の形になる。
    ///
    /// 正しくは「そのパスを載せるはずのボリュームが表に居るか」を見る。
    /// macOS では起動ボリューム以外は `/Volumes/<名前>` に現れるので、
    /// そこを取り出して照合する。
    ///
    /// **パスの実体は見ない** — 見た瞬間にブロックし得るうえ、
    /// `/Volumes/<名前>` は外れても空のフォルダとして残ることがあるため
    /// `fileExists` では判定できない。
    ///
    /// - Note: 判定できないとき（マウント表が読めない等）は **`true`** に倒す。
    ///   ``isRemote(path:)`` が `false` に倒すのと向きが逆だが、どちらも
    ///   「呼び出し側にとって害の小さいほう」で揃えてある——こちらで
    ///   誤って `false` に倒すと、繋がっているのに履歴を捨ててしまう。
    public func isOnAnUnmountedVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // 起動ボリュームより深いマウントが実際に載せているなら、繋がっている。
        // `/Volumes/.timemachine/<UUID>/<日付>.backup` のように入口が
        // `/Volumes/<名前>` より深い形もここで正しく拾える。
        if let entry = entry(containing: path), entry.mountPoint != "/" { return false }
        // どのボリュームにも載っていない。`/Volumes/` 配下を名乗っているなら、
        // それは**そのボリュームが表から消えた**ということ。
        guard let volumeRoot = Self.volumeRoot(of: path) else { return false }
        return !isMounted(volumeRoot)
    }

    /// パスが載っているボリュームの入口 `/Volumes/<名前>`。
    /// 起動ボリューム上のパス（`/Volumes/` 配下でないもの）なら `nil`。
    ///
    /// **純粋な文字列処理で、ファイルシステムにもマウント表にも触れない。**
    /// そのため「ボリューム単位で答えを覚える」ときのキーとして安く使える
    /// （`FileIconProvider` が行ごとの判定をこれで畳んでいる）。
    public static func volumeRoot(of path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        guard !name.isEmpty else { return nil }
        return prefix + name
    }

    /// そのマウント先がいま存在するか。
    public func isMounted(_ mountPoint: String) -> Bool {
        let target = Self.normalized(mountPoint)
        return entries.contains { $0.mountPoint == target }
    }

    // MARK: - パスの扱い

    /// 末尾のスラッシュだけを落とす。
    ///
    /// **`NSString.standardizingPath` / `URL.resolvingSymlinksInPath()` は
    /// 使わない。** どちらも「先頭が `/private` なら取り除く」特別扱いを持ち、
    /// 本プロジェクトはこれで一度 `DirectoryChangeHub` の照合を落としている
    /// （一時ディレクトリ配下のイベントが 1 件も引き当たらなくなった）。
    /// ここへ渡すのは既に解決済みのパスである前提で、余計な変換をしない。
    static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// `path` が `ancestor` そのものか、その配下か。
    ///
    /// 素の `hasPrefix` では `/Volumes/Private` が `/Volumes/PrivateArchive`
    /// に一致してしまうので、**区切りまで含めて**確かめる。
    static func path(_ path: String, isAtOrUnder ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        if path == ancestor { return true }
        return path.hasPrefix(ancestor + "/")
    }

    /// C の固定長文字配列を Swift の文字列にする。
    private static func string<T>(from field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
