//
//  右ペインのカバー画像 [CV-01〜CV-08][DS-06]。
//
//  **解決順序（①ユーザー指定 → ②サイドカー → ③先頭画像）をここ 1 箇所に
//  持つ** [IV-03][9章 §9.6]。①は DB、②は実体、③は `ThumbnailService` と
//  出どころが分かれているので、判定を View に散らすと「どれが出ているのか」を
//  誰も答えられなくなる。
//
//  判定を `QooApplication` に置く理由は `RatingEditorModel` と同じ
//  （アプリターゲットのコードは `swift test` から触れない）。
//
import Foundation
import Observation
import QooInfrastructure
import QooKit

@MainActor
@Observable
public final class CoverEditorModel {
    public enum State: Sendable, Equatable {
        case notApplicable
        case loading
        case notInLibrary
        case ready(Subject)
        case failed(String)
    }

    public struct Subject: Sendable, Equatable {
        public let id: FileID
        /// 対象そのもの（アーカイブ／フォルダ）。
        public let url: URL
        public let filename: String
        /// DB に入っている割り当て。**Undo の「変更前」**。
        public let assignment: CoverAssignment
        /// 実際に表示へ使う画像。`nil` なら自動抽出（`ThumbnailService` に任せる）。
        public let imageURL: URL?
        /// 解決の結果、いま何が出ているか [IV-03]。DB の値ではなく**実際に
        /// 表示されているもの**——ユーザー指定なのに複製が失われていれば
        /// `.sidecar` や `.auto` になる。
        public let resolvedSource: CoverSource
        /// 中身をカバーとして選べる種別か [CV-05]。
        public let canPickFromArchive: Bool

        public init(id: FileID, url: URL, filename: String, assignment: CoverAssignment,
                    imageURL: URL?, resolvedSource: CoverSource, canPickFromArchive: Bool) {
            self.id = id
            self.url = url
            self.filename = filename
            self.assignment = assignment
            self.imageURL = imageURL
            self.resolvedSource = resolvedSource
            self.canPickFromArchive = canPickFromArchive
        }

        /// サムネイルを要求する URL。自動抽出のときは対象そのものを渡すので、
        /// 呼び出し側は分岐せずに `ThumbnailService` を呼べる。
        public var previewURL: URL { imageURL ?? url }

        /// 「既定に戻す」を出すか [CV-07]。
        ///
        /// **DB がユーザー指定を持っているときだけ。** サイドカーは DB に
        /// 書いていない（下記）ので、戻す対象は常にユーザー指定である。
        public var canRevert: Bool { assignment.source == .userSpecified }
    }

    public private(set) var state: State = .notApplicable

    private let commands: CommandStack
    private var services: LibraryServices?
    private var loadedURL: URL?
    private var loadedLibrary: LibrarySummary?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 読み込み

    /// ## サイドカーは DB に書かない［設計判断］
    /// 仕様の疑似コード [9章 §9.6] は②で DB を見ずに実体を探している。
    /// `coverImageSource = .sidecar` を保存すると、あとから `covers/` に画像を
    /// 置いた・消したときに DB が古いまま残り、**画面と実体が食い違う**。
    /// 毎回探すのは `covers` フォルダ 1 つの列挙で済むので、費用も釣り合う。
    public func load(url: URL?, library: LibrarySummary?, services: LibraryServices) async {
        self.services = services
        self.loadedLibrary = library
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
            let assignment = CoverAssignment(row)
            let userCoverURL = assignment.ref.map {
                services.userCoverURL(ref: $0, library: library)
            }
            // **①②③ の順序は `CoverResolution` が持つ** [IV-03]。ライブラリ
            // 表示モードの一覧のセルも同じ関数を通る——同じに見えるものに
            // 独立した実装を 2 つ作らない。
            let resolved = await CoverResolution.resolve(
                url: url, assignment: assignment, userCoverURL: userCoverURL)
            state = .ready(Subject(
                id: row.id, url: url, filename: row.filename, assignment: assignment,
                imageURL: resolved.imageURL, resolvedSource: resolved.source,
                canPickFromArchive: Self.canPickFromArchive(url)))
        } catch {
            // **取り消しは失敗ではない**［2-9 の実機検証でユーザーが発見］。
            // `.task(id:)` は鍵が変わると前のタスクを取り消すので、選択を
            // 素早く変えたり読み直しの合図（`operationHistory.count`・
            // `contentRevision`）が続けて来たりすると、ここへ
            // `CancellationError` が届く。そのまま出すと画面に
            // 「タイトル: CancellationError()」という、利用者にとって
            // 意味の無い赤字が残る——**直後に新しい読み込みが正しい値を
            // 入れる**ので、出しても一瞬で消える（あるいは消えない）という
            // 最も分かりにくい形になる。状態は次の読み込みが上書きする。
            guard !CommandStack.isCancellation(error) else { return }
            state = .failed(String(describing: error))
        }
    }

    /// アーカイブ内のページを選べるか [CV-05]。フォルダも「中の画像を選ぶ」が
    /// 素直に成り立つので含める（ブックフォルダ [IF-14]）。
    nonisolated public static func canPickFromArchive(_ url: URL) -> Bool {
        switch PreviewableFileKind.of(url) {
        case .archive, .epub, .folder: true
        case .image, .video, .pdf, .other: false
        }
    }

    // MARK: - 操作

    /// 好きな画像に差し替える [CV-02][CV-03][CV-04][CV-05]。
    ///
    /// - Parameter data: 画像の生バイト列。**呼び出し側が読み込む**——ダイアログ・
    ///   D&D・アーカイブ内エントリで取り出し方が違うだけで、ここから先は同じ
    ///   操作である（`SetRatingCommand` を単発と一括で共有しているのと同じ形）。
    public func replace(withImageData data: Data) async throws {
        guard case .ready(let subject) = state, let services, let library = loadedLibrary
        else { return }
        // **先に複製を作る。** DB を先に書くと、複製の書き込みに失敗したときに
        // 「参照はあるが実体が無い」行が残る——表示は既定へ落ちるので、
        // 何が起きたのか画面からは読み取れない。
        let ref = try await services.storeUserCover(data, library: library)
        try await commands.run(SetCoverCommand(
            fileID: subject.id, url: subject.url,
            previous: subject.assignment, next: .userSpecified(ref: ref),
            subjectName: subject.filename, kind: .replace, services: services))
        await reload()
    }

    /// 自動抽出へ戻す [CV-07]。
    ///
    /// **複製は消さない** — ⌘Z で戻せる操作なので、消すと取り消した先に実体が
    /// 無い（`UserCoverStore` の型コメント参照）。
    public func revert() async throws {
        guard case .ready(let subject) = state, let services else { return }
        guard subject.canRevert else { return }
        try await commands.run(SetCoverCommand(
            fileID: subject.id, url: subject.url,
            previous: subject.assignment, next: .automatic,
            subjectName: subject.filename, kind: .revert, services: services))
        await reload()
    }

    /// 書き込みのあと、解決をやり直す。**楽観的に組み立てない**——
    /// ユーザー指定を外した結果サイドカーが出る、といった遷移があるので、
    /// 同じ手順で解決し直すほうが食い違わない。
    private func reload() async {
        guard let services else { return }
        await load(url: loadedURL, library: loadedLibrary, services: services)
    }
}
