//
//  右ペインのタイトル編集 [RP-10〜RP-12][DT-08][DT-09]。
//
//  **`qooLibraryApp` ではなく `QooApplication` に置く**——判定（未設定なら
//  ファイル名へ落とす [IV-07]、手動編集のときだけ「再取得」を出す [RP-12]、
//  空欄をどう扱うか）を自動テストで固定できなくなるため
//  （`RatingEditorModel`/`LabelEditorModel` と同じ理由）。SwiftUI には依存しない。
//
import Foundation
import Observation
import QooKit

/// 右ペインが 1 つ持つ、選択中のファイルのタイトル。
@MainActor
@Observable
public final class TitleEditorModel {
    /// タイトル欄の状態。値の意味は `RatingEditorModel.State` と揃えてある
    /// ——同じ右ペインの中で欄ごとに出ない理由が違うと読み取れない。
    public enum State: Sendable, Equatable {
        case notApplicable
        case loading
        case notInLibrary
        case ready(Subject)
        case failed(String)
    }

    public struct Subject: Sendable, Equatable {
        public let id: FileID
        public let url: URL
        /// ファイル名（拡張子つき）。**タイトルが未設定のときの表示にも使う** [IV-07]。
        public let filename: String
        /// DB の `title`。`nil` は未設定。
        public let title: String?
        /// 自動更新から守られているスコープ [PR-02]。基本情報の鍵の表示と、
        /// ⌘Z の戻り先に使う。
        public let protectedScopes: Set<ProtectionScope>
        public let seriesName: String?
        public let volume: VolumeValue

        public init(id: FileID, url: URL, filename: String, title: String?,
                    protectedScopes: Set<ProtectionScope>,
                    seriesName: String?, volume: VolumeValue) {
            self.id = id
            self.url = url
            self.filename = filename
            self.title = title
            self.protectedScopes = protectedScopes
            self.seriesName = seriesName
            self.volume = volume
        }

        /// 基本情報が保護されているか [PR-02]。鍵アイコンの出どころ。
        public var isBasicProtected: Bool { protectedScopes.contains(.basic) }

        /// 入力欄に出す文字列。**未設定でもファイル名を入れない** [設計判断]
        /// ——入れると、何も打たずに確定しただけで「ファイル名と同じタイトルを
        /// 手で付けた」ことになり、以後の自動抽出が効かなくなる [PR-03]。
        /// ファイル名は欄の外（プレースホルダ）で見せる。
        public var editableText: String { title ?? "" }

        /// タイトルが無いときに代わりに見せる文字列 [IV-07]。
        public var fallbackTitle: String {
            (filename as NSString).deletingPathExtension
        }

        /// 「ファイル名から再取得」を出すか [RP-12]。
        ///
        /// **保護されているときだけ。** 保護が無ければ押しても何も変わらず、
        /// 「効果のない導線が常駐する」ことになる（`RatingEditorModel` の
        /// `canApplyToSeries` と同じ判断）。押すと保護が解ける [PR-04]。
        public var canRederive: Bool { isBasicProtected }

        /// 巻数の表示 [DT-09]。原文表記を優先する——`第01巻` を `1` と
        /// 出し直すと、ファイル名に書いてある表記と食い違って見える。
        public var volumeDisplay: String? {
            if let raw = volume.raw, !raw.isEmpty { return raw }
            guard volume.kind == .numeric, let number = volume.number else { return nil }
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
    }

    public private(set) var state: State = .notApplicable

    private let commands: CommandStack
    private var services: LibraryServices?
    private var loadedURL: URL?
    private var loadedLibrary: LibrarySummary?
    /// いま DB に入っている値一式。**Undo の「変更前」として使う。**
    ///
    /// `Subject` に持たせないのは、この画面に出ていない列（著者名）まで
    /// 含める必要があるから——編集で書き戻すときに落とすと、**タイトルを
    /// 直しただけで著者が消える。**
    private var current: FileFieldEdit?

    public init(commands: CommandStack = .shared) {
        self.commands = commands
    }

    // MARK: - 読み込み

    public func load(url: URL?, library: LibrarySummary?, services: LibraryServices) async {
        self.services = services
        self.loadedLibrary = library
        guard let url, let library, services.isReady else {
            loadedURL = nil
            current = nil
            state = .notApplicable
            return
        }
        if loadedURL != url {
            state = .loading
            loadedURL = url
        }
        do {
            guard let row = try await services.fileRow(at: url, in: library) else {
                current = nil
                state = .notInLibrary
                return
            }
            current = FileFieldEdit(row)
            state = .ready(Subject(id: row.id, url: url, filename: row.filename,
                                   title: row.title, protectedScopes: row.protectedScopes,
                                   seriesName: row.seriesName, volume: row.volume))
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
            current = nil
            state = .failed(String(describing: error))
        }
    }

    // MARK: - 操作

    /// 入力欄を離れたとき・Return が押されたときに、実際に書き込むべきか [RP-10]。
    ///
    /// **利用者が打っていなければ書かない。** 欄をクリックしただけ、あるいは
    /// ⌘Z の直後にフォーカスが外れただけで確定させると、**値は同じなのに
    /// `titleOrigin` だけが `.manual` になる**——以後その行は自動抽出から
    /// 守られてしまい [RP-11]、画面上は何も変わらないので気づけない
    /// ［実機検証で発見］。
    ///
    /// **この 1 行が「利用者が決めた」の定義なので、View に埋めない**
    /// （`starsAfterTapping` [RA-02] と同じ理由）。
    nonisolated public static func shouldCommit(draft: String, lastKnown: String) -> Bool {
        draft != lastKnown
    }

    /// タイトルを手動値で確定する [RP-10][RP-11]。
    ///
    /// **値が変わらないときは何もしない**（Undo スタックを無意味に汚さない）。
    /// ただし保護されていなければ、同じ文字列でも書く——「この値を自分で
    /// 決めた」という表明そのものが意味を持つ [PR-03]。
    public func commitTitle(_ text: String) async throws {
        try await commit(kind: .editTitle) { $0.settingTitle(text) }
    }

    /// シリーズ名を手動値で確定する [RP-13]。**基本情報は 1 かたまり** [PR-02]
    /// なので、タイトルと同じスコープが保護される。
    public func commitSeriesName(_ text: String) async throws {
        try await commit(kind: .editSeriesName) { $0.settingSeriesName(text) }
    }

    /// 巻数を手動値で確定する [RP-14]。
    ///
    /// **数値として読めない入力は書かない**（`VolumeValue.parsingUserInput` が
    /// `nil` を返す）——`.none` に落とすと、打ち間違いが「巻数を消す操作」
    /// として黙って通る。
    public func commitVolume(_ text: String) async throws {
        guard let volume = VolumeValue.parsingUserInput(text) else { return }
        try await commit(kind: .editVolume) { $0.settingVolume(volume) }
    }

    private func commit(kind: SetFileFieldsCommand.Kind,
                        _ transform: (FileFieldEdit) -> FileFieldEdit) async throws {
        guard case .ready(let subject) = state, let services, let previous = current else { return }
        let next = transform(previous)
        // 値も保護も変わらないなら何もしない。
        guard next != previous || !subject.isBasicProtected else { return }
        try await commands.run(SetFileFieldsCommand(
            fileID: subject.id, url: subject.url, previous: previous, next: next,
            previousScopes: subject.protectedScopes,
            subjectName: subject.filename, kind: kind, services: services))
        apply(next, to: subject, protectedScopes: subject.protectedScopes.union([.basic]))
    }

    /// ファイル名から導き直す [RP-12]。タイトルに加えてシリーズ名・巻数・著者も
    /// 戻す［ユーザー判断］。**ラベルは触らない**——手で付けたラベルが
    /// 巻き添えで消えると、取り消すまで気づけない。
    public func rederive() async throws {
        guard case .ready(let subject) = state, let services, let library = loadedLibrary
        else { return }
        // **書く直前に引き直す** — 表示していた値は読み込み時のもので、その間に
        // ⌘Z が走っていれば「変更前」として古い値を持つことになる
        // （`RatingEditorModel.applyToSeries` で同じ形を直している）。
        guard let row = try await services.fileRow(at: subject.url, in: library) else { return }
        let previous = FileFieldEdit(row)
        let next = try await services.rederivedFields(for: row)
        // **値が同じでも保護は外す** [PR-04]。「再取得」は値を戻す操作である
        // と同時に保護の解除でもあり、たまたま自動値と一致していたからと
        // いって鍵が残ると、押しても何も起きないように見える。
        try await commands.run(SetFileFieldsCommand(
            fileID: subject.id, url: subject.url, previous: previous, next: next,
            previousScopes: row.protectedScopes,
            subjectName: subject.filename, kind: .rederive, services: services))
        apply(next, to: subject,
              protectedScopes: row.protectedScopes.subtracting([.basic]))
    }

    private func apply(_ edit: FileFieldEdit, to subject: Subject,
                       protectedScopes: Set<ProtectionScope>) {
        current = edit
        state = .ready(Subject(id: subject.id, url: subject.url, filename: subject.filename,
                               title: edit.title, protectedScopes: protectedScopes,
                               seriesName: edit.seriesName, volume: edit.volume))
    }
}
