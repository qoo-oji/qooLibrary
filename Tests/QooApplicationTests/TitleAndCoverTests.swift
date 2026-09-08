import Foundation
import CoreGraphics
import ImageIO
import QooInfrastructure
import QooKit
import Testing
@testable import QooApplication

//
//  タイトル編集 [RP-10〜RP-12] とカバー画像 [CV-02〜CV-08]。
//
//  DB を実際に開いて確かめる——守っているのは「再スキャンで手動編集が
//  消えないこと」「⌘Z が印まで戻すこと」という**書き込みの性質**なので、
//  リポジトリを偽物に差し替えると肝心の部分が試せない（`RatingCommandTests`
//  と同じ理由）。`ServicesWorkspace` を共有する。
//

@Suite("タイトルとカバー [RP-10〜RP-12][CV-02〜CV-08]", .serialized)
struct TitleAndCoverTests {

    /// 一般コミック を使う——同人誌 は巻数フォーマットを持たないので
    /// **シリーズ名も巻数も取れず、再取得 [RP-12] の主張が成り立たない**
    /// （2-19 で 4 件落として学んだ形）。
    @MainActor
    private func workspace(files: [String] = ["(一般コミック) [著者値A] 作品名A 第01巻.cbz"])
        async throws -> (ServicesWorkspace, LibrarySummary, [URL])
    {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        for name in files { try w.write(name) }
        let id = try await w.enable("builtin.general-comic")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        return (w, library, files.map { w.libraryRoot.appendingPathComponent($0) })
    }

    private func png() -> Data {
        // 8x8 の PNG。中身は問わない——`UserCoverStore` が「画像として読めるか」
        // だけを見る。
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: - タイトル [RP-10][RP-11]

    @Test("タイトルを手動で書くと基本情報が保護される [RP-10][PR-03]")
    @MainActor
    func editingTitleProtectsBasicScope() async throws {
        let (w, library, urls) = try await workspace()
        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("手で付けた題")

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.title == "手で付けた題")
        #expect(row.protectedScopes.contains(.basic))
    }

    /// **これが崩れると、手で直したタイトルが次の走査で黙って消える。**
    /// 守っているのは `applyParsedFields`（保護スコープを読んで据え置く）。
    @Test("保護された基本情報は再スキャンで上書きされない [PR-01]")
    @MainActor
    func manualTitleSurvivesRescan() async throws {
        let (w, library, urls) = try await workspace()
        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("手で付けた題")

        _ = try await w.services.scan(libraryID: library.id, root: w.libraryRoot)

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.title == "手で付けた題")
        #expect(row.protectedScopes.contains(.basic))
    }

    /// **保護まで戻す。** 値だけ戻して鍵を残すと、次の再スキャンで自動抽出が
    /// 効かないまま——しかも取り消した直後は正しく見えるので気づけない。
    @Test("⌘Z はタイトルと保護の両方を戻す [UD-01][PR-03]")
    @MainActor
    func undoRestoresTitleAndProtection() async throws {
        let (w, library, urls) = try await workspace()
        let before = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(!before.protectedScopes.contains(.basic))

        let stack = CommandStack()
        let model = TitleEditorModel(commands: stack)
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("手で付けた題")
        _ = await stack.undo()

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.title == before.title)
        #expect(!row.protectedScopes.contains(.basic), "⌘Z は保護も戻す")
    }

    @Test("同じ値の確定では Undo に積まない")
    @MainActor
    func noOpEditIsNotRecorded() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let model = TitleEditorModel(commands: stack)
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("題")
        let depth = stack.operationHistory.count
        try await model.commitTitle("題")
        #expect(stack.operationHistory.count == depth)
    }

    /// **入力欄に触れただけで `manual` にしない** [RP-10][RP-11]。
    ///
    /// 実機で踏んだ形: ⌘Z でタイトルを取り消したあとフォーカスを外すと、値は
    /// 正しいのに印だけが戻っていた。以後その行は自動抽出から守られるが、
    /// **画面上は何も変わらないので気づけない。**
    @Test("打っていなければ確定しない [RP-10]")
    func doesNotCommitWithoutTyping() {
        #expect(!TitleEditorModel.shouldCommit(draft: "作品名A", lastKnown: "作品名A"))
        #expect(TitleEditorModel.shouldCommit(draft: "作品名A 改", lastKnown: "作品名A"))
        #expect(TitleEditorModel.shouldCommit(draft: "", lastKnown: "作品名A"),
                "空にしたのは「打った」——未設定へ戻す意思表示 [RP-11]")
    }

    // MARK: - メディア向けの 4 欄 [MF-03〜05][MF-19]

    /// **読めない入力は書かない**（`commitVolume` と同じ判断 [RP-14]）。
    /// `nil` に落とすと、打ち間違いが「値を消す操作」として黙って通る。
    /// **空欄だけは未設定へ戻す**——消す意思が読み取れる唯一の形。
    @Test("数の欄は、読めない入力を書かず、空欄だけ未設定に戻す [MF-04][MF-05]")
    func theNumberFieldsRejectUnreadableInput() {
        #expect(TitleEditorModel.parseNumber("5") == .some(.some(5)))
        #expect(TitleEditorModel.parseNumber(" 12 ") == .some(.some(12)))
        // 全角で打っても通る［機械が人間に合わせる］。
        #expect(TitleEditorModel.parseNumber("１２") == .some(.some(12)))
        #expect(TitleEditorModel.parseNumber("5.5") == .some(.some(5.5)))
        #expect(TitleEditorModel.parseNumber("") == .some(nil), "空欄は未設定へ戻す")
        #expect(TitleEditorModel.parseNumber("  ") == .some(nil))
        #expect(TitleEditorModel.parseNumber("五") == nil, "読めないので何もしない")
        #expect(TitleEditorModel.parseNumber("1話") == nil)
        #expect(TitleEditorModel.parseNumber("-1") == nil, "負の話数は無い")
    }

    /// **ISO 8601 の部分形しか通さない** [MF-19]。`releaseDate` は文字列のまま
    /// 比較で並べる列なので、書式が混ざると並び順が壊れる。
    @Test("公開日は ISO 8601 の部分形だけを受け取り、桁を揃える [MF-19]")
    func theReleaseDateFieldNormalisesToISO8601() {
        #expect(TitleEditorModel.parseReleaseDate("2024") == .some("2024"))
        #expect(TitleEditorModel.parseReleaseDate("2024-01") == .some("2024-01"))
        #expect(TitleEditorModel.parseReleaseDate("2024-01-15") == .some("2024-01-15"))
        // **1 桁で打っても 0 詰めする**——揃えないと `2024-9` が `2024-10` より
        // 後ろに並ぶ（文字列比較のため）。
        #expect(TitleEditorModel.parseReleaseDate("2024-1-5") == .some("2024-01-05"))
        #expect(TitleEditorModel.parseReleaseDate("") == .some(nil), "空欄は未設定へ戻す")
        #expect(TitleEditorModel.parseReleaseDate("2024/01/15") == nil)
        #expect(TitleEditorModel.parseReleaseDate("24-01-15") == nil)
        #expect(TitleEditorModel.parseReleaseDate("2024-13") == nil)
        #expect(TitleEditorModel.parseReleaseDate("2024-01-32") == nil)
        #expect(TitleEditorModel.parseReleaseDate("令和6年") == nil)
    }

    /// **値が 1 つも無ければ 4 行を出さない** [設計判断]。コミックの蔵書で
    /// 空の欄が 4 つ常駐すると、右ペインを簡潔に保つ方針に反する。
    @Test("メディアの 4 行は、値があるときだけ出す")
    func theMediaRowsAppearOnlyWhenThereIsSomethingToShow() {
        func subject(subtitle: String? = nil, season: Double? = nil,
                     episode: Double? = nil, releaseDate: String? = nil)
        -> TitleEditorModel.Subject {
            TitleEditorModel.Subject(
                id: FileID(rawValue: 1), url: URL(fileURLWithPath: "/tmp/a.mp4"),
                filename: "a.mp4", title: nil, protectedScopes: [],
                seriesName: nil, volume: .none,
                subtitle: subtitle, season: season, episode: episode,
                releaseDate: releaseDate)
        }
        #expect(!subject().showsMediaFields)
        #expect(subject(subtitle: "副題").showsMediaFields)
        #expect(subject(season: 1).showsMediaFields)
        #expect(subject(episode: 1).showsMediaFields)
        #expect(subject(releaseDate: "2024").showsMediaFields)
        #expect(TitleEditorModel.Subject.numberDisplay(5) == "5", "整数は小数点を出さない")
        #expect(TitleEditorModel.Subject.numberDisplay(nil) == "")
    }

    /// **4 つとも実際に DB へ書けること。** モデルの `commit*` は右ペインの
    /// 唯一の入口 [MF-10] だが、**実機検証の時点で View の行が 1 つも無く**、
    /// この 4 つを呼ぶ経路がどこにも無かった（2026-09-08）。行を足したので、
    /// ここで書き込みまで固定しておく——`parseNumber`/`parseReleaseDate` の
    /// 入力検査だけでは「読めた値が列へ着く」ことを試せない。
    @Test("メディアの 4 欄は DB へ書け、基本情報が保護される [MF-03〜05][MF-19][PR-03]")
    @MainActor
    func editingMediaFieldsWritesEveryColumnAndProtectsTheBasicScope() async throws {
        let (w, library, urls) = try await workspace()
        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)

        try await model.commitSeason("2")
        try await model.commitEpisode("12.5")
        try await model.commitSubtitle("手で付けた副題")
        try await model.commitReleaseDate("2024-1-5")

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.season == 2)
        #expect(row.episode == 12.5)
        #expect(row.subtitle == "手で付けた副題")
        #expect(row.releaseDate == "2024-01-05", "0 詰めして書く")
        #expect(row.protectedScopes.contains(.basic), "基本情報は 1 かたまり [PR-02]")
    }

    /// **⌘Z が 4 列とも戻す。** 保護スコープも一緒に戻らないと、取り消した
    /// のに走査が触れないままになる。
    @Test("メディアの 4 欄の編集は取り消せる [UD-01]")
    @MainActor
    func undoingAMediaFieldEditRestoresTheColumnAndTheProtection() async throws {
        let (w, library, urls) = try await workspace()
        let commands = CommandStack()
        let model = TitleEditorModel(commands: commands)
        await model.load(url: urls[0], library: library, services: w.services)

        try await model.commitEpisode("7")
        #expect(try await w.services.fileRow(at: urls[0], in: library)?.episode == 7)

        _ = await commands.undo()
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.episode == nil)
        #expect(!row.protectedScopes.contains(.basic))
    }

    // MARK: - 再取得 [RP-12]

    @Test("ファイル名から再取得すると自動値へ戻り保護も解ける [RP-12][PR-04]")
    @MainActor
    func rederiveRestoresAutomaticValues() async throws {
        let (w, library, urls) = try await workspace()
        let auto = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(auto.seriesName == "作品名A", "前提: 自動抽出が効いている")

        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("手で付けた題")
        try await model.rederive()

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.title == auto.title)
        #expect(!row.protectedScopes.contains(.basic))
        #expect(row.seriesName == auto.seriesName)
        #expect(row.volume == auto.volume)
        #expect(row.authorName == auto.authorName)
    }

    /// **再取得はメディアの 4 値も導き直す** [MF-10][RP-12]。
    ///
    /// `setFields` はこの 4 列も書くので、`rederivedFields` が落とすと
    /// **「ファイル名から再取得」が話数を消す**——ファイル名にはちゃんと
    /// 書いてあるのに、押した瞬間に空になる。
    @Test("再取得はメディアの 4 値も戻す [MF-10]")
    @MainActor
    func rederiveAlsoRestoresMediaFields() async throws {
        let w = try ServicesWorkspace()
        await w.bootstrap()
        let name = "作品名 S02E05「副題」.mp4"
        try w.write(name)
        let id = try await w.enable("builtin.video-series")
        _ = try await w.services.scan(libraryID: id, root: w.libraryRoot)
        let library = try #require(w.services.library(registrationUUID: w.registrationUUID))
        let url = w.libraryRoot.appendingPathComponent(name)
        let auto = try #require(try await w.services.fileRow(at: url, in: library))
        #expect(auto.episode == 5, "前提: 走査が話数を入れている")

        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: url, library: library, services: w.services)
        try await model.commitTitle("手で付けた題")
        try await model.rederive()

        let row = try #require(try await w.services.fileRow(at: url, in: library))
        #expect(row.season == 2)
        #expect(row.episode == 5)
        #expect(row.subtitle == "副題")
    }

    @Test("再取得の ⌘Z は手動編集を戻す [RP-12][UD-01]")
    @MainActor
    func undoRederiveRestoresManualEdit() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let model = TitleEditorModel(commands: stack)
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.commitTitle("手で付けた題")
        try await model.rederive()
        _ = await stack.undo()

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.title == "手で付けた題")
        #expect(row.protectedScopes.contains(.basic))
    }

    /// **正規化キーも書き直す。** 書かないと、手で直したシリーズ名では
    /// 「シリーズ全巻」[RA-04] が引けなくなる——しかも件数を見ても気づけない。
    @Test("シリーズ名を書き換えると全巻の照合も追随する")
    @MainActor
    func editingSeriesKeepsSeriesLookupWorking() async throws {
        let (w, library, urls) = try await workspace(files: [
            "(一般コミック) [著者値A] 作品名A 第01巻.cbz",
            "(一般コミック) [著者値A] 作品名A 第02巻.cbz",
        ])
        let first = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(try await w.services.filesInSameSeries(as: first.id).count == 2)

        var edit = FileFieldEdit(first)
        edit.seriesName = "別のシリーズ"
        try await w.services.setFileFields(edit, id: first.id, protectedScopes: [.basic])

        let after = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(after.seriesName == "別のシリーズ")
        #expect(try await w.services.filesInSameSeries(as: after.id).count == 1,
                "正規化キーが書き換わっていれば、別シリーズとして 1 冊だけ引ける")
    }

    // MARK: - モデルの状態

    @Test("ライブラリ経由でなければ欄を出さない [LF-01 と同じ判断]")
    @MainActor
    func noLibraryMeansNotApplicable() async throws {
        let (w, _, urls) = try await workspace()
        let title = TitleEditorModel(commands: CommandStack())
        await title.load(url: urls[0], library: nil, services: w.services)
        #expect(title.state == .notApplicable)

        let cover = CoverEditorModel(commands: CommandStack())
        await cover.load(url: urls[0], library: nil, services: w.services)
        #expect(cover.state == .notApplicable)
    }

    @Test("DB に行が無ければ理由を出す")
    @MainActor
    func fileOutsideTheLibraryIsReported() async throws {
        let (w, library, _) = try await workspace()
        try w.write("メモ.txt")                     // 対象拡張子ではない [AL-11]
        let url = w.libraryRoot.appendingPathComponent("メモ.txt")
        let model = TitleEditorModel(commands: CommandStack())
        await model.load(url: url, library: library, services: w.services)
        #expect(model.state == .notInLibrary)
    }

    // MARK: - カバー [CV-02][CV-06][CV-07]

    @Test("画像を指定すると複製が作られ、DB は参照だけを持つ [CV-06]")
    @MainActor
    func replacingCoverStoresACopy() async throws {
        let (w, library, urls) = try await workspace()
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.coverImageSource == .userSpecified)
        let ref = try #require(row.coverImageRef)
        #expect(FileManager.default.fileExists(
            atPath: w.services.userCoverURL(ref: ref, library: library).path))
        guard case .ready(let subject) = model.state else { Issue.record("ready でない"); return }
        #expect(subject.resolvedSource == .userSpecified)
        #expect(subject.canRevert)
    }

    @Test("既定に戻すと自動抽出へ戻り、参照は消える [CV-07]")
    @MainActor
    func revertingClearsTheReference() async throws {
        let (w, library, urls) = try await workspace()
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())
        try await model.revert()

        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.coverImageSource == .auto)
        #expect(row.coverImageRef == nil)
    }

    /// **複製は消さない。** 消すと ⌘Z の戻り先に実体が無くなる。
    @Test("既定に戻しても複製は残り、⌘Z で戻せる [CV-07][UD-01]")
    @MainActor
    func undoRevertBringsBackTheCover() async throws {
        let (w, library, urls) = try await workspace()
        let stack = CommandStack()
        let model = CoverEditorModel(commands: stack)
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())
        let ref = try #require(try await w.services.fileRow(at: urls[0], in: library)?.coverImageRef)
        try await model.revert()
        #expect(FileManager.default.fileExists(
            atPath: w.services.userCoverURL(ref: ref, library: library).path),
            "戻す先の実体が消えていてはならない")

        _ = await stack.undo()
        let row = try #require(try await w.services.fileRow(at: urls[0], in: library))
        #expect(row.coverImageSource == .userSpecified)
        #expect(row.coverImageRef == ref)
    }

    @Test("参照されている複製は起動時の掃除で消えない [CV-06]")
    @MainActor
    func purgeKeepsReferencedCovers() async throws {
        let (w, library, urls) = try await workspace()
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())
        let kept = try #require(try await w.services.fileRow(at: urls[0], in: library)?.coverImageRef)
        // 参照されない複製をもう 1 つ作る（差し替えを重ねた状態）。
        try await model.replace(withImageData: png())
        let newest = try #require(try await w.services.fileRow(at: urls[0], in: library)?.coverImageRef)

        await w.services.purgeUnreferencedUserCovers()

        #expect(FileManager.default.fileExists(
            atPath: w.services.userCoverURL(ref: newest, library: library).path))
        #expect(!FileManager.default.fileExists(
            atPath: w.services.userCoverURL(ref: kept, library: library).path),
            "差し替えで参照が外れた複製は起動時に捨てる")
    }

    /// サイドカー [IV-02②] は DB に書かない——解決のたびに実体を探す。
    @Test("ユーザー指定はサイドカーより優先する [IV-03]")
    @MainActor
    func userSpecifiedWinsOverSidecar() async throws {
        let (w, library, urls) = try await workspace()
        try w.write("covers/(一般コミック) [著者値A] 作品名A 第01巻.png")
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        guard case .ready(let sidecar) = model.state else { Issue.record("ready でない"); return }
        #expect(sidecar.resolvedSource == .sidecar, "指定が無ければ covers/ を使う")
        #expect(!sidecar.canRevert, "サイドカーは DB に書かないので戻す対象が無い")

        try await model.replace(withImageData: png())
        guard case .ready(let user) = model.state else { Issue.record("ready でない"); return }
        #expect(user.resolvedSource == .userSpecified)
    }

    /// 複製が失われても**表示は既定へ落ちるだけ**で、戻す手段は残す
    /// （残さないと迷子の参照を片付けられない）。
    @Test("複製が失われたら自動へ落ちるが、戻す導線は残す")
    @MainActor
    func missingCopyFallsBackButStaysRevertable() async throws {
        let (w, library, urls) = try await workspace()
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())
        let ref = try #require(try await w.services.fileRow(at: urls[0], in: library)?.coverImageRef)
        try FileManager.default.removeItem(at: w.services.userCoverURL(ref: ref, library: library))

        await model.load(url: urls[0], library: library, services: w.services)
        guard case .ready(let subject) = model.state else { Issue.record("ready でない"); return }
        #expect(subject.resolvedSource == .auto)
        #expect(subject.imageURL == nil)
        #expect(subject.canRevert)
    }

    @Test("ライブラリを消すと複製も片付く [CV-06]")
    @MainActor
    func removingTheLibraryDropsItsCovers() async throws {
        let (w, library, urls) = try await workspace()
        let model = CoverEditorModel(commands: CommandStack())
        await model.load(url: urls[0], library: library, services: w.services)
        try await model.replace(withImageData: png())
        let ref = try #require(try await w.services.fileRow(at: urls[0], in: library)?.coverImageRef)

        try await w.services.disable(registrationUUID: w.registrationUUID, keepData: false)

        #expect(!FileManager.default.fileExists(
            atPath: w.services.userCoverURL(ref: ref, library: library).path))
    }
}
