//
//  右ペインの評価 [RA-01〜RA-08]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——アプリターゲットの
//  コードは `swift test` から触れないため、判定（同じ星の再クリックで解除
//  [RA-02]、シリーズ名が無ければ全巻適用を無効 [RA-07]、DB に行が無いときの
//  見せ方）を自動テストで固定できなくなる（`LabelFilterModel` と同じ理由）。
//  SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 右ペインが 1 つ持つ、選択中のファイルの評価。
@MainActor
@Observable
public final class RatingEditorModel {
    /// 評価欄の状態。
    public enum State: Sendable, Equatable {
        /// ライブラリ経由で開いていない、またはライブラリ機能が使えない。
        /// **欄ごと出さない**——ボリューム経由で見ているだけのフォルダに
        /// 評価の枠が出ると、それが何に対する評価なのか読み取れない
        /// [LF-01 と同じ判断]。
        case notApplicable
        case loading
        /// ライブラリの中だが DB に行が無い（対象拡張子外・まだ走査されて
        /// いない）。**無効の星と理由を出す**［ユーザー判断］——黙って消すと
        /// 「星を付けられない」のか「壊れている」のか区別が付かない。
        case notInLibrary
        case ready(Subject)
        /// 読み込みに失敗した [ER-01]。
        case failed(String)
    }

    /// 評価の対象 1 件。
    public struct Subject: Sendable, Equatable {
        public let id: FileID
        public let url: URL
        public let displayName: String
        public let stars: Int
        public let seriesName: String?
        /// 同じシリーズの冊数 [RA-05]。`nil` はシリーズ名を持たない [RA-07]。
        public let seriesCount: Int?
        /// シリーズのどれかに星が付いているか。
        ///
        /// **「全巻に適用」を出すかどうかの判定に要る**［実機検証で発見］。
        /// 未評価のまま「全巻の評価を解除」を常駐させると、何もしていない
        /// 状態の一番目立つ位置に、押すと他の巻の星が消える導線が座る。
        public let seriesHasAnyRating: Bool

        /// 「このシリーズ全巻に適用」を出すか [RA-04]。
        ///
        /// **効果があるときだけ出す。** 星が付いていれば「適用」、付いて
        /// いなくてもシリーズのどこかに星があれば「解除」に意味がある。
        /// どちらでもなければ何も起きないので出さない。
        public var canApplyToSeries: Bool {
            guard let seriesCount, seriesCount > 1 else { return false }
            return stars > 0 || seriesHasAnyRating
        }

        public init(id: FileID, url: URL, displayName: String, stars: Int,
                    seriesName: String?, seriesCount: Int?, seriesHasAnyRating: Bool = false) {
            self.id = id
            self.url = url
            self.displayName = displayName
            self.stars = stars
            self.seriesName = seriesName
            self.seriesCount = seriesCount
            self.seriesHasAnyRating = seriesHasAnyRating
        }
    }

    public private(set) var state: State = .notApplicable

    private let commands: CommandStack
    private var services: LibraryServices?
    /// 「全巻に適用」で書く対象。**ボタンに出した件数と同じ一覧を使う**
    /// ——実行時に引き直すと、表示した件数と実際に書いた件数がずれうる。
    private var seriesRows: [FileRow] = []
    /// 診断ログ用の絶対パスを組み立てるためのライブラリ根 [LG2-06]。
    private var libraryRoot: URL?
    /// 直近で読み込んだ対象。**同じ対象の読み直しではスピナーへ戻さない**
    /// ——星を押すたび、また無関係なファイル操作のたびに読み直しが走るので、
    /// そのたびに枠の中身が消えると激しくちらつく（`SingleItemInspector` の
    /// `loadedURL` と同じ理由）。
    private var loadedURL: URL?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 読み込み

    /// 選択中のファイルの評価を読む。
    ///
    /// - Parameters:
    ///   - url: 選択中のファイル。`nil` なら欄を出さない。
    ///   - library: そのファイルが属するライブラリ。ボリューム経由で開いて
    ///     いる場合は `nil`（**URL から逆算しない**——`NavigationRoot` の
    ///     約束に従い、判定は呼び出し側の責務）。
    public func load(url: URL?, library: LibrarySummary?, services: LibraryServices) async {
        self.services = services
        seriesRows = []
        libraryRoot = library.map { URL(fileURLWithPath: $0.resolvedPath) }
        guard let url, let library, services.isReady else {
            loadedURL = nil
            state = .notApplicable
            return
        }
        if loadedURL != url {
            state = .loading
            loadedURL = url
        }
        do {
            guard let row = try await services.fileRow(at: url, in: library) else {
                state = .notInLibrary
                return
            }
            // シリーズの冊数は「全巻に適用」を出すときだけ要る [RA-05][RA-07]。
            var count: Int?
            var anyRated = false
            if row.seriesName?.isEmpty == false {
                seriesRows = try await services.filesInSameSeries(as: row.id)
                count = seriesRows.count
                anyRated = seriesRows.contains { $0.rating > 0 }
            }
            state = .ready(Subject(
                id: row.id, url: url, displayName: row.filename, stars: row.rating,
                seriesName: row.seriesName, seriesCount: count, seriesHasAnyRating: anyRated))
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            // `.task(id:)` は鍵が変わると前のタスクを取り消すので、選択を
            // 素早く変えたり読み直しの合図（`LibraryGeneration`）が
            // 続けて来たりすると、ここへ
            // `CancellationError` が届く。そのまま出すと画面に
            // 「タイトル: CancellationError()」という、利用者にとって
            // 意味の無い赤字が残る——**直後に新しい読み込みが正しい値を
            // 入れる**ので、出しても一瞬で消える（あるいは消えない）という
            // 最も分かりにくい形になる。状態は次の読み込みが上書きする。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    // MARK: - 操作

    /// 星が押されたときに書き込む値 [RA-01][RA-02]。
    ///
    /// **同じ星をもう一度押したら解除**（0）。切り出してあるのは、この 1 行が
    /// RA-02 そのものだから——View に埋めるとテストで固定できない。
    nonisolated public static func starsAfterTapping(_ tapped: Int, current: Int) -> Int {
        tapped == current ? 0 : tapped
    }

    /// 星を押す [RA-01][RA-02]。値が変わらないときは何もしない
    /// （Undo スタックを無意味に汚さない）。
    public func setStars(tapped: Int) async throws {
        guard case .ready(let subject) = state, let services else { return }
        let stars = Self.starsAfterTapping(tapped, current: subject.stars)
        guard stars != subject.stars else { return }
        try await run(SetRatingCommand(
            targets: [RatingTarget(id: subject.id, url: subject.url,
                                   previousStars: subject.stars)],
            stars: stars, subjectName: subject.displayName, services: services),
            newStars: stars, subject: subject)
    }

    /// このシリーズ全巻に、いまの評価を適用する [RA-04][RA-06]。
    ///
    /// **1 つの `Command` にまとめる**——巻ごとに分けると ⌘Z を冊数ぶん押す
    /// 羽目になり、しかも途中まで戻した状態が残る。変更前の値は 1 件ずつ
    /// 持つので、巻ごとに評価が違っていても ⌘Z で元どおりになる。
    public func applyToSeries() async throws {
        guard case .ready(let subject) = state, let services,
              let seriesName = subject.seriesName, !seriesRows.isEmpty else { return }
        // **書く直前に引き直す。**`seriesRows` は読み込み時のもので、その後に
        // 星を押していれば基準の巻の評価が既に古い——そのまま「変更前の値」
        // として使うと、⌘Z が**いま持っていない値**へ戻す。読み直しは
        // `.task` が後から走るが、それを待ってから押されるとは限らない。
        //
        // 件数がボタンに出したものと違っていても、そのまま進める——いま
        // 実際にシリーズを構成している巻に書くほうが正しい（差が出るのは
        // 表示してから押すまでに巻が増減した場合だけ）。
        seriesRows = try await services.filesInSameSeries(as: subject.id)
        guard !seriesRows.isEmpty else { return }
        let root = libraryRoot
        let targets = seriesRows.map { row in
            RatingTarget(
                id: row.id,
                url: root?.appendingPathComponent(row.relativePath) ?? subject.url,
                previousStars: row.rating)
        }
        try await run(SetRatingCommand(
            targets: targets, stars: subject.stars, subjectName: subject.displayName,
            seriesName: seriesName, services: services),
            newStars: subject.stars, subject: subject)
    }

    private func run(_ command: SetRatingCommand, newStars: Int, subject: Subject) async throws {
        _ = try await commands.run(command)
        state = .ready(Subject(
            id: subject.id, url: subject.url, displayName: subject.displayName,
            stars: newStars, seriesName: subject.seriesName,
            seriesCount: subject.seriesCount,
            // 星を付けた直後は、少なくともこの 1 冊が評価済み。読み直し
            // （`.task`）が届くまでの間も「全巻に適用」を正しく出せる。
            seriesHasAnyRating: subject.seriesHasAnyRating || newStars > 0))
    }
}
