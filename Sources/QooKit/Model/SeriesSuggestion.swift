//
//  シリーズのヒューリスティック検出（提案）[SS-01〜SS-08、19章 §19.5]。
//
//  シリーズ名の抽出はユーザー定義のフォーマット（正規表現）に頼っており、
//  **どうやっても漏れが出る**。特に同人誌では、当初シリーズ化予定のなかった
//  作品が続編でシリーズ化され、1 冊目にだけナンバリングが無い、という形が
//  頻出する。ここはその**救済**であって、フォーマットによる解析の代替では
//  ない——先にフォーマット解析が走り、その取りこぼしだけが対象になる。
//
//  ## 勝手に設定しない [SS-01]
//  この型が返すのは**提案**で、書き込みは行わない。適用するかどうかは
//  メンテナンスの「シリーズの提案」タブで利用者が決める。
//
//  ## 純粋関数だけを置く
//  DB も設定も見ない。候補の集め方（どのファイルを渡すか [SS-08]・著者と
//  サークルをどう引くか [SS-02]）は呼び出し側の仕事で、ここは渡されたものを
//  並べ替えて畳むだけ——ゴールデンテストの流儀（合成名の正例・負例）で
//  固定できる形にするため。
//
import Foundation

/// 検出に渡す本 1 冊 [SS-02]。
public struct SeriesSuggestionCandidate: Sendable, Hashable, Identifiable {
    public let id: FileID
    /// タイトル（**原文**）。提案するシリーズ名はここから切り出す [SS-03]。
    public let title: String
    /// 同一フォルダの判定に使う鍵 [SS-02]。相対パスの親。
    public let folderPath: String
    /// 著者・サークルの名前 [SS-02]。**正規化済みのものを呼び出し側が入れる**
    /// ——ここで正規化すると、呼び出し側が DB から引いた値との突き合わせが
    /// 2 通りになる。
    ///
    /// **空なら候補にならない。** 「著者（またはサークル）が一致」という条件を
    /// 満たしようがないため（同じフォルダにあるだけの無関係な本が、接頭辞
    /// だけでまとまってしまう）。
    public let groupingKeys: Set<String>
    /// 「以後この提案を出さない」[SS-05]。**印を立てた時点のタイトルと現在の
    /// タイトルが一致するときだけ真**——名前が変われば判断の前提が消える
    /// （`unresolvedFile.isIgnored` [UR2-04] と同じ考え方）。
    ///
    /// **検出はこの印を見ない**［設計判断］。無視は「この提案は出さなくてよい」
    /// という**表示の判断**であって、組み方の判断ではない——除いて組むと、
    /// 無視した 2 冊に 3 冊目が加わったときに「状況が変わった」ことに気づけ
    /// なくなる（3 冊目が 1 冊だけ残り、提案そのものが現れない）。組んだ結果に
    /// 対して「全員が無視されている組は出さない」と判断するのは呼び出し側。
    public let isIgnored: Bool

    public init(id: FileID, title: String, folderPath: String,
                groupingKeys: Set<String>, isIgnored: Bool = false) {
        self.id = id
        self.title = title
        self.folderPath = folderPath
        self.groupingKeys = groupingKeys
        self.isIgnored = isIgnored
    }
}

/// 提案 1 件 [SS-01][SS-04]。**2 冊以上でしか作られない。**
public struct SeriesSuggestion: Sendable, Hashable, Identifiable {
    public struct Member: Sendable, Hashable, Identifiable {
        public let id: FileID
        /// タイトル（原文）。
        public let title: String
        /// 提案する巻数 [SS-07]。`.none` = 巻なし。
        ///
        /// **番号の無い 1 冊目に 1 を推測して割り当てない**——「1 冊目だから
        /// 1 巻」は当たっていることが多いが、外れたときに直す手がかりが
        /// 画面のどこにも残らない。
        ///
        /// `VolumeValue` をそのまま持つのは、**適用が書き込む値と、一覧が
        /// 見せる値を同じものにする**ため。数値と原文表記を別々の欄で持つと、
        /// 片方だけ直したときに静かに食い違う。
        public let volume: VolumeValue

        public init(id: FileID, title: String, volume: VolumeValue) {
            self.id = id
            self.title = title
            self.volume = volume
        }
    }

    /// 提案するシリーズ名（**原文の綴り**）[SS-03]。末尾の記号・空白は除いてある。
    public let seriesName: String
    /// メンバーが居るフォルダ（相対パスの親）[SS-02]。画面で「どこの話か」を
    /// 示すのに使う。
    public let folderPath: String
    /// メンバー。**タイトル順**（畳んだ形での昇順）。
    public let members: [Member]

    /// **最小のメンバー ID**。1 冊は高々 1 つの提案にしか入らない（重なりは
    /// 検出側で解いてある）ので、これで一意になる。
    ///
    /// **初期化のときに決めて持つ**［code-review の指摘］——計算プロパティに
    /// すると、メンバーが空のとき（呼び出し側の誤り）に添字で落ちる。ここでは
    /// 意味を持たない ID へ落として、落ちる場所を作らない。
    public let id: FileID

    public init(seriesName: String, folderPath: String, members: [Member]) {
        self.seriesName = seriesName
        self.folderPath = folderPath
        self.members = members
        // `members` は 2 件以上であること（`SeriesSuggestionDetector` が保証する）。
        self.id = members.min { $0.id.rawValue < $1.id.rawValue }?.id
            ?? FileID(rawValue: 0)
    }
}

/// 1 ライブラリぶんの検出結果。
///
/// **提案と無視印を分けて返す。** 無視は「この組は出さなくてよい」という
/// 表示の判断で、組み方の判断ではない（`SeriesSuggestionCandidate.isIgnored`
/// の注記を参照）——組んだ結果に対して呼び出し側が当てはめる。
public struct SeriesSuggestionReport: Sendable, Hashable {
    public let suggestions: [SeriesSuggestion]
    /// 「以後出さない」印が、**現在のタイトルに対して**立っている本 [SS-05]。
    public let ignoredFileIDs: Set<FileID>

    public init(suggestions: [SeriesSuggestion], ignoredFileIDs: Set<FileID>) {
        self.suggestions = suggestions
        self.ignoredFileIDs = ignoredFileIDs
    }

    /// この組は「全員が無視されている」か [SS-05]。
    ///
    /// **全員が揃ったときだけ無視とみなす。** 無視はグループ単位の操作なので
    /// 全員に印が付く——一部だけ付いている組は、名前が変わった・別の本が
    /// 加わった、という**状況が変わった**しるしなので出す。
    public func isIgnored(_ suggestion: SeriesSuggestion) -> Bool {
        suggestion.members.allSatisfy { ignoredFileIDs.contains($0.id) }
    }
}

/// 検出器 [SS-02][SS-03][SS-04][SS-07]。/// 検出器 [SS-02][SS-03][SS-04][SS-07]。
public enum SeriesSuggestionDetector {

    // MARK: - 入口

    /// 候補から提案を作る。
    ///
    /// - Parameter minimumNameLength: 提案するシリーズ名の最小の長さ [SS-02]。
    ///   既定は `AppLimits.SeriesSuggestion.minimumNameLength`。
    public static func detect(
        _ candidates: [SeriesSuggestionCandidate],
        minimumNameLength: Int = AppLimits.SeriesSuggestion.minimumNameLength
    ) -> [SeriesSuggestion] {
        let usable = candidates.filter { !$0.title.isEmpty && !$0.groupingKeys.isEmpty }
        guard usable.count >= 2 else { return [] }

        let prepared = usable.map(Prepared.init)

        // ① （フォルダ × 著者/サークル）ごとに分ける [SS-02]。
        //
        // **1 冊が複数のバケツへ入りうる**——著者とサークルの両方が取れて
        // いれば、著者で揃う相手ともサークルで揃う相手とも組になり得る。
        // 重なりは ③ で解く。
        var buckets: [BucketKey: [Prepared]] = [:]
        for item in prepared {
            for key in item.candidate.groupingKeys {
                buckets[BucketKey(folderPath: item.candidate.folderPath, groupingKey: key),
                        default: []].append(item)
            }
        }

        // ② バケツごとに、隣り合うタイトルを畳んでいく。
        var drafts: [Draft] = []
        for (bucket, items) in buckets {
            drafts.append(contentsOf: runs(in: items, bucket: bucket,
                                           minimumNameLength: minimumNameLength))
        }

        // ③ 重なりを解く。
        return resolve(drafts, minimumNameLength: minimumNameLength)
    }

    // MARK: - 準備（照合用の畳み込み）

    /// タイトルを**原文と照合用で位置が 1 対 1 に対応する**形にしたもの。
    ///
    /// SS-03 が「照合は正規化を通し、表示は元の綴りを使う」と定めるので、
    /// 畳んだ側で求めた接頭辞の長さを原文へ写せなければならない。
    /// `TextNormalizer.normalize` は空白を畳む（長さが変わる）ので使えず、
    /// `canonicalWidth`（幅畳み込み＋NFC）＋小文字化を使う。
    struct Prepared {
        let candidate: SeriesSuggestionCandidate
        let original: [Character]
        let folded: [Character]
        /// 並べ替え用（`folded` の文字列表現）。
        let sortKey: String

        init(_ candidate: SeriesSuggestionCandidate) {
            self.candidate = candidate
            let original = Array(candidate.title)
            let folded = SeriesSuggestionDetector.fold(candidate.title, original: original)
            self.original = original
            self.folded = folded
            self.sortKey = String(folded)
        }
    }

    /// 原文と**同じ文字数**の照合用の配列を返す。
    ///
    /// まとめて畳んで文字数が変わらなければそれを使い、変わったときだけ
    /// 1 文字ずつ畳む（04章 §4.6 で「並行文字列を作らず 1 文字ずつ畳んで
    /// 比べる」としたのと同じ手）。**まとめて畳んだ結果を無条件に使っては
    /// ならない**——半角カナの合成のように 2 文字が 1 文字になる写像が
    /// 将来入ると、接頭辞の長さを原文へ写した時点でずれる。
    static func fold(_ title: String, original: [Character]) -> [Character] {
        let quick = Array(TextNormalizer.canonicalWidth(title).lowercased())
        if quick.count == original.count { return quick }
        return original.map { c in
            let f = TextNormalizer.canonicalWidth(String(c)).lowercased()
            return f.first ?? c
        }
    }

    struct BucketKey: Hashable {
        let folderPath: String
        let groupingKey: String
    }

    // MARK: - ② 隣り合うタイトルを畳む

    struct Draft {
        let bucket: BucketKey
        let members: [Prepared]
        let prefixLength: Int
    }

    static func runs(in items: [Prepared], bucket: BucketKey,
                     minimumNameLength: Int) -> [Draft] {
        guard items.count >= 2 else { return [] }
        // ID まで見て並べる——同じタイトルが複数あっても順序が決まるように。
        let sorted = items.sorted {
            $0.sortKey == $1.sortKey ? $0.candidate.id.rawValue < $1.candidate.id.rawValue
                                     : $0.sortKey < $1.sortKey
        }

        var drafts: [Draft] = []
        var current: [Prepared] = [sorted[0]]
        var prefixLength = sorted[0].folded.count

        func flush() {
            guard current.count >= 2,
                  let accepted = accept(current, prefixLength: prefixLength,
                                        minimumNameLength: minimumNameLength)
            else { return }
            drafts.append(Draft(bucket: bucket, members: current,
                                prefixLength: accepted.prefixLength))
        }

        for next in sorted.dropFirst() {
            // **グループ全体の共通接頭辞**で判定する [SS-02 の「共通接頭辞」]。
            // 隣接ペアだけを見て繋いでいくと、A-B と B-C がそれぞれ長くても
            // A-C は短い、という連鎖でグループが際限なく伸びる。
            let shared = min(prefixLength, commonPrefixLength(current[0].folded, next.folded))
            let extended = current + [next]
            if shared > 0,
               accept(extended, prefixLength: shared, minimumNameLength: minimumNameLength) != nil {
                current = extended
                prefixLength = shared
            } else {
                flush()
                current = [next]
                prefixLength = next.folded.count
            }
        }
        flush()
        return drafts
    }

    static func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit, a[i] == b[i] { i += 1 }
        return i
    }

    // MARK: - 受け入れ判定 [SS-03][SS-04][SS-07]

    struct Accepted {
        let seriesName: String
        let volumes: [VolumeValue]
        /// 数字の途中で切れないよう後退させた後の長さ（下記）。
        let prefixLength: Int
    }

    /// この接頭辞で提案してよいか。
    ///
    /// 境界は SS-03 の 2 つの手がかりで判定する:
    /// - **(a) 全員の残りが「空」か「素の数字」** ——「1 冊目にだけ番号が無い」
    ///   という、この機能が救おうとしている形そのもの
    /// - **(b) 接頭辞の末尾が記号・空白** —— `作品A - 前編` のような形
    ///
    /// どちらも満たさなければ提案しない。これが誤検出を止める主役で、
    /// たとえば `教師と生徒` と `教師と生活` は (a) が「徒／活」で落ち、
    /// (b) も「生」が記号でないので落ちる。
    static func accept(_ members: [Prepared], prefixLength: Int,
                       minimumNameLength: Int) -> Accepted? {
        guard members.count >= 2, prefixLength > 0 else { return nil }
        // **全員が同じタイトルなら重複であってシリーズではない** [DU-01 の担当]。
        //
        // **接頭辞の長さを見て判定しない**［code-review の指摘］。数字で終わる
        // タイトルは後退（下記）で接頭辞が短くなるので、「接頭辞より長い本が
        // いるか」で見ると `作品タイトル1` が 2 冊あるだけで「1 巻が 2 冊ある
        // シリーズ」になってしまう——適用は保護まで書くので、走査で直る道も
        // 塞がれる。
        guard Set(members.map { String($0.folded) }).count >= 2 else { return nil }
        // **数字の途中で切らない。** `作品タイトル1` と `作品タイトル10` の
        // 共通接頭辞は `作品タイトル1` になり、そのまま採ると「シリーズ
        // 作品タイトル1 の 0 巻」という嘘の分解になる。末尾の数字は巻数の側の
        // ものなので、接頭辞から出す。
        let prefixLength = backOffTrailingDigits(members[0].folded, prefixLength)
        guard prefixLength > 0 else { return nil }
        guard members.allSatisfy({ $0.folded.count >= prefixLength }) else { return nil }

        let rawPrefix = String(members[0].original.prefix(prefixLength))
        let seriesName = trimTrailingSeparators(rawPrefix)
        guard seriesName.count >= minimumNameLength else { return nil }

        // 巻数は**メンバーごとに**判定する [SS-07]。残りが素の数字として
        // 読めない本は「巻なし」で、それだけでグループを壊さない。
        //
        // 数値は畳んだ側から読み（全角数字に当たる）、`raw` は原文から採る
        // ——`VolumeValue` の規約どおり、表記を失わない。
        let volumes: [VolumeValue] = members.map { member in
            let foldedRest = String(member.folded[prefixLength...])
            guard let n = plainNumber(foldedRest) else { return .none }
            let rawRest = TextNormalizer.trimWhitespace(String(member.original[prefixLength...]))
            return .numeric(n, raw: rawRest)
        }
        let restsAreCleanCuts = members.enumerated().allSatisfy { index, member in
            member.folded.count == prefixLength || volumes[index].kind == .numeric
        }
        let prefixEndsAtSeparator = rawPrefix.last.map(isSeparator) ?? false
        guard restsAreCleanCuts || prefixEndsAtSeparator else { return nil }

        return Accepted(seriesName: seriesName, volumes: volumes, prefixLength: prefixLength)
    }

    /// 接頭辞が数字で終わっていたら、その数字の並びごと外す。
    ///
    /// **接頭辞が数字で終わっているときだけ**行う——`作品1 - 前編` /
    /// `作品1 - 後編` のように数字がシリーズ名の一部である形は、接頭辞が
    /// 区切りで終わるのでここを通らない。
    static func backOffTrailingDigits(_ folded: [Character], _ length: Int) -> Int {
        var end = length
        while end > 0, folded[end - 1].isASCII, folded[end - 1].isNumber { end -= 1 }
        return end
    }

    /// 末尾の記号・空白を落とす [SS-03]。
    static func trimTrailingSeparators(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            guard isSeparator(s[prev]) else { break }
            end = prev
        }
        return String(s[s.startIndex..<end])
    }

    static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation || c.isSymbol
    }

    /// 「素の数字として読める」か [SS-07]。
    ///
    /// **前後の空白だけを落とす。** 記号まで落とすと `-2` が 2 巻になり、
    /// 区切りが接頭辞に含まれるべきだった場合（`作品-1` / `作品-2` は接頭辞が
    /// `作品-` になり (b) で通る）と結果が食い違う。
    static func plainNumber(_ s: String) -> Double? {
        let t = TextNormalizer.trimWhitespace(s)
        guard !t.isEmpty, t.count <= 12, t.first != ".", t.last != "." else { return nil }
        var digits = 0
        var dots = 0
        for c in t {
            if c.isASCII, c.isNumber { digits += 1 }
            else if c == "." { dots += 1 }
            else { return nil }
        }
        guard digits > 0, dots <= 1 else { return nil }
        return Double(t)
    }

    // MARK: - ③ 重なりを解く

    /// **1 冊は高々 1 つの提案にしか入らない。** 同じ本が 2 つの提案に現れると、
    /// 片方を適用したときにもう片方の意味が黙って変わる（残りのメンバーだけで
    /// 別の接頭辞になる）。大きい・長いものから採り、取られたメンバーを除いた
    /// 残りで作り直す。
    static func resolve(_ drafts: [Draft], minimumNameLength: Int) -> [SeriesSuggestion] {
        let ranked = drafts.sorted { a, b in
            if a.members.count != b.members.count { return a.members.count > b.members.count }
            if a.prefixLength != b.prefixLength { return a.prefixLength > b.prefixLength }
            if a.bucket.folderPath != b.bucket.folderPath {
                return a.bucket.folderPath < b.bucket.folderPath
            }
            return (a.members[0].candidate.id.rawValue) < (b.members[0].candidate.id.rawValue)
        }

        var claimed: Set<FileID> = []
        var result: [SeriesSuggestion] = []
        for draft in ranked {
            let remaining = draft.members.filter { !claimed.contains($0.candidate.id) }
            guard remaining.count >= 2 else { continue }
            // 残ったメンバーだけの共通接頭辞は**伸びうる**ので求め直す。
            var prefixLength = remaining[0].folded.count
            for item in remaining.dropFirst() {
                prefixLength = min(prefixLength,
                                   commonPrefixLength(remaining[0].folded, item.folded))
            }
            guard let accepted = accept(remaining, prefixLength: prefixLength,
                                        minimumNameLength: minimumNameLength)
            else { continue }
            let members = zip(remaining, accepted.volumes).map { item, volume in
                SeriesSuggestion.Member(id: item.candidate.id,
                                        title: item.candidate.title,
                                        volume: volume)
            }
            result.append(SeriesSuggestion(seriesName: accepted.seriesName,
                                           folderPath: draft.bucket.folderPath,
                                           members: members))
            claimed.formUnion(members.map(\.id))
        }

        // 画面の並びが実行のたびに変わらないように決めておく。
        return result.sorted {
            if $0.folderPath != $1.folderPath { return $0.folderPath < $1.folderPath }
            if $0.seriesName != $1.seriesName { return $0.seriesName < $1.seriesName }
            return $0.id.rawValue < $1.id.rawValue
        }
    }
}
