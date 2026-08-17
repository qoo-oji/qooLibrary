import Foundation
import QooKit

public enum RegisteredFolderKind: String, Codable, Sendable, Equatable {
    case library, temporary
}

public struct RegisteredFolder: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: RegisteredFolderKind
    public var displayName: String // [RG-05]
    public var bookmarkData: Data // [RG-07]

    /// この登録フォルダの配下ではサムネイル・カバー画像を**常に**表示しない
    /// [DS-04]。フェーズ2で SwiftData の `Library` が入ったらそちらの属性へ
    /// 移す（仕様書 07章 §7.2 / 09章 DS2-04）。
    ///
    /// **「既定値」ではなく「強制」の意味にしている** [設計判断、ユーザー確認済み。
    /// 仕様書側も同じ意味に訂正済み]。要件の文言は「ライブラリごとに既定値を
    /// 持てる」だが、全体トグルは DS-03 によりアプリ全体で共有される状態なので、
    /// 「ライブラリへ入った瞬間に全体トグルが書き換わる」形にすると**他の
    /// ウインドウの表示まで巻き添えで変わる**。そのため全体トグルを書き換えず、
    /// 実効値を `全体トグルOFF || このフラグ` として合成する形にした。
    /// 要件が挙げる運用（「特定のライブラリだけ常に非表示にする」）はこちらで
    /// 素直に満たせる。
    ///
    /// **`Bool?`（Optional）なのは後方互換のため。** Swift の合成された
    /// `Decodable` はプロパティの既定値を使わず、キーが無いと `keyNotFound` で
    /// 失敗する（実測で確認済み）。既存の `registeredFolders.json` にはこの
    /// キーが無いため、Optional にして「キーが無い＝未設定」を表現する
    /// [`AppAssociationStore.StorageDTO.hasUnifiedDefaults` と同じ理由・同じ手法]。
    /// 読むときは常に ``hidesThumbnails`` を使うこと。
    public var thumbnailsAlwaysHidden: Bool?

    /// ``thumbnailsAlwaysHidden`` の未設定を `false` に畳んだ読み出し口。
    public var hidesThumbnails: Bool { thumbnailsAlwaysHidden ?? false }

    /// **最後にブックマークを解決できたときのパス** [RG3-02 の実装、1-17]。
    /// 解決に成功するたびに更新する。
    ///
    /// ## 仕様書の `volumeUUID` からこれに替えた理由［ユーザー判断、実測にもとづく］
    /// 仕様書 RG3-02 は当初「`volumeUUID: String?` を持ち、マウント済み
    /// ボリュームの UUID 一覧と突き合わせる」と定めていた。目的は
    /// **`.offline`（未接続）と `.missing`（消失）の区別**で、これは
    /// ブックマークの失敗コードだけでは付かない——実測すると
    /// **イジェクトも完全削除も等しく `NSCocoaErrorDomain code=4`** だった
    /// （`.withoutMounting` を付けても同じ）。
    ///
    /// パスを持つほうが優れているのは次の 3 点による:
    ///
    /// 1. **判定に I/O が要らない。** ``MountTable/isOnAnUnmountedVolume(_:)``
    ///    はカーネルのマウント表を写すだけで、どのファイルシステムにも
    ///    問い合わせない [NV6-02]。UUID 方式だと一覧を作るのに各ボリュームへ
    ///    `resourceValues`／`statfs` が要り、**応答しない共有が 1 つあると
    ///    そこで詰まる**——判定したい当の状況（切断）で判定が固まる。
    /// 2. **SMB でも効く。** `volumeUUIDString` はネットワーク共有では
    ///    必ず `nil` になる（1-16b の実測、8章 §8.11.2）。
    /// 3. **UI と再選択にそのまま使える。** 「見つかりません: <パス>」の表示と、
    ///    「場所を選び直す…」パネルの開始位置がこの 1 つの値で賄える。
    ///
    /// - Note: 既知の限界。**同名の別ドライブに差し替えられた**場合
    ///   （`/Volumes/T7` を抜いて、別の「T7」を挿す）は「マウントされている」
    ///   と見えるため `.missing` と誤判定する。自動解除はしない [RG3-04] ので
    ///   実害は「見つかりませんと表示される」ことに留まり、正しいドライブを
    ///   挿し直せば次の更新で `.online` に戻る。
    ///
    /// `Bool?` の ``thumbnailsAlwaysHidden`` と同じ理由で `Optional` にしてある
    /// ——Swift の合成された `Decodable` はプロパティの既定値を使わないため、
    /// 非 Optional で足すと**既存の `registeredFolders.json` が丸ごと
    /// デコードに失敗し、登録が全部消えたように見える**（`load()` は失敗を
    /// 退避して空で続行するため）。`nil` は「まだ一度も解決できていない」を表す。
    public var lastKnownPath: String?

    public init(
        id: UUID = UUID(),
        kind: RegisteredFolderKind,
        displayName: String,
        bookmarkData: Data,
        thumbnailsAlwaysHidden: Bool? = nil,
        lastKnownPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.thumbnailsAlwaysHidden = thumbnailsAlwaysHidden
        self.lastKnownPath = lastKnownPath
    }
}

/// 完全削除で実体を失う登録フォルダと、その削除前の解決済みパス
/// [`RegisteredFolderStore.registrationsInvalidated(byDeleting:)` 参照]。
public struct InvalidatedRegistration: Sendable, Equatable {
    public let folder: RegisteredFolder
    /// 削除**前**に解決したパス。削除後は解決できないため、ここに控えておく。
    public let resolvedPath: String

    public init(folder: RegisteredFolder, resolvedPath: String) {
        self.folder = folder
        self.resolvedPath = resolvedPath
    }
}

public enum RegisteredFolderError: Error, Sendable, Equatable {
    case nestedRegistration // [RG-03][RG-04]
    case unsupportedFileSystem(VolumeRejection) // [RG-08]
    /// 指定された ID の登録が無い。`relocate(_:to:)` が、解除済みの登録に
    /// 対して呼ばれた場合（「場所を選び直す…」のパネルを開いたまま、別の
    /// ウインドウで解除した等）に投げる。
    case notRegistered
}

/// [ER-03]［監査で発見］。`FolderTreePane` は自前の対応表でこの 2 つを
/// 日本語にしているが、それは登録パネル経由の 1 箇所だけ。ほかの経路
/// （将来の初回セットアップウィザード 2-17 など）から出たときに
/// 「エラー0」形式へ落ちないよう、型自身にも説明を持たせる。
extension RegisteredFolderError: UserPresentableError {
    public var whatHappened: String {
        switch self {
        case .nestedRegistration: "このフォルダは登録できません。"
        case .unsupportedFileSystem: "このフォルダがあるボリュームは登録に対応していません。"
        case .notRegistered: "この登録フォルダは見つかりませんでした。"
        }
    }

    public var whyItHappened: String {
        switch self {
        case .nestedRegistration:
            return "すでに登録されているフォルダの中、または親にあたるフォルダだからです。"
        case .notRegistered:
            return "操作している間に、別の場所で登録が解除されたようです。"
        case let .unsupportedFileSystem(reason):
            switch reason {
            case let .noPersistentFileID(fileSystem), let .persistentIDNotPreserved(fileSystem):
                return "\(fileSystem) は、ファイルを移動しても同一と判別できる仕組みに対応していません。"
                    + "この仕組みが無いと、移動や改名のたびにラベル・評価・カバー画像との"
                    + "結びつきが失われてしまいます。"
            }
        }
    }

    public var recoverySuggestions: [RecoveryAction] { [] }

    public var recoveryHint: String? {
        switch self {
        case .nestedRegistration: "すでに登録した場所と重ならないフォルダを選んでください。"
        case .unsupportedFileSystem: "APFS または Mac OS 拡張のボリューム上のフォルダを選んでください。"
        case .notRegistered: "登録し直してください。"
        }
    }

    public var technicalDetail: String? { nil }
    public var severity: NotificationSeverity { .sheet }
}

extension RegisteredFolderError: LocalizedError {
    public var errorDescription: String? {
        [whatHappened, whyItHappened, recoveryHint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// フォルダ登録の永続化 [8.7 節、RG-01〜RG-08]。1-13 の時点ではまだ SwiftData
/// （`Library`/`TemporaryFolder` モデル）が無いため、ロードマップの注記通り
/// **「エイリアス相当」**に留める: 実フォルダへの参照（Security-Scoped
/// Bookmark）と表示名だけを持つ軽量なレコードを JSON で永続化する。
/// ラベル・テンプレート・初回フルスキャン等のドメイン処理（8.7 節 疑似コードの
/// ⑤）は一切行わない（フェーズ2で `LibraryRepository`〈SwiftData 版〉に
/// 置き換える想定、07章 §7.5 参照）。
///
/// JSON ファイルへの書き込みはアプリ内部の永続化データであり、期待変更台帳・
/// Undo・操作履歴の対象外（ユーザーへ見える最終位置ではない）ため、
/// `SecureExtractor`/`CoverImageCache` と同じ理由で `FileOperationService` を
/// 経由しない。この理由により、本ファイルは FileOps 隔離検査（B-10）の対象外
/// ディレクトリ（`QooInfrastructure/FileOps/`）に置く。
public actor RegisteredFolderStore {
    public static let shared = RegisteredFolderStore()

    private let storageURL: URL
    private let bookmarks: BookmarkResolving
    private let volumeChecker: VolumeEligibilityChecking
    private var folders: [RegisteredFolder] = []
    /// アクセスを開始したままにしている URL を**登録 ID で**引けるようにする。
    /// URL の集合として持つと、実体が消えた登録（完全削除された
    /// ライブラリ／テンポラリ）を解除するときにブックマークを再解決できず、
    /// `stopAccessingSecurityScopedResource()` を呼べないまま
    /// エントリだけが残り続ける [完全削除 FM-14 実装時のレビューで発見]。
    private var activeAccessURLs: [UUID: URL] = [:]
    /// 初回読み込みのメモ化 [NV6-05]。`ensureLoaded()` が await を含むように
    /// なったため、actor 再入で二重に読み込まないよう「読み込み中」を単なる
    /// `Bool` ではなく await できる `Task` として持つ。
    private var loadTask: Task<Void, Never>?
    /// ブックマーク解決 1 回あたりの上限時間 [NV6-05]。テストでは短縮できる。
    private let resolutionDeadline: Duration

    /// テストでは独立したストレージ・依存を注入できる（`SecureExtractor`/
    /// `ArchiveCompressor` の `stagingRoot` 注入と同じ設計判断）。
    public init(
        storageURL: URL? = nil,
        bookmarks: BookmarkResolving = SecurityScopedBookmarkResolver(),
        volumeChecker: VolumeEligibilityChecking = VolumeEligibilityChecker(),
        resolutionDeadline: Duration = .seconds(AppLimits.FileOperations.bookmarkResolutionTimeoutSeconds)
    ) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageURL = appSupport.appendingPathComponent("qooLibrary/registeredFolders.json")
        }
        self.bookmarks = bookmarks
        self.volumeChecker = volumeChecker
        self.resolutionDeadline = resolutionDeadline
    }

    /// 起動時に一度だけ呼ぶ。保存済みの登録フォルダを読み込み、それぞれの
    /// Security-Scoped Bookmark へのアクセスを開始する。
    ///
    /// **個々の読み取り操作のたびに start/stop するのではなく、登録されている
    /// 間はアプリ終了までスコープを保持し続ける方針**にした
    /// [1-2 の実機検証で確認済みのパターン: ブックマーク解決後にアクセスを
    /// 開始したまま保てば、再起動をまたいでも同じフォルダへアクセスできる]。
    /// これにより `FolderTreeNode.children(of:)`/`FolderContentView.reload()`
    /// など、すでに実装済みの素の `FileManager` 呼び出し（読み取り専用、FileOps
    /// 隔離検査の対象外）を一切変更せずに登録フォルダにも対応できる。
    public func loadAndActivateAll() async {
        await ensureLoaded()
    }

    public func folders(kind: RegisteredFolderKind) async -> [RegisteredFolder] {
        await ensureLoaded()
        return folders
            .filter { $0.kind == kind }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 起動時にセキュリティスコープを開始できた登録の件数。
    ///
    /// **ブックマークの再解決を伴わない**（読み込み時の結果をそのまま数える）
    /// ため、呼んでも副作用が無い。診断情報の収集 [CB-22] のように
    /// 「今この瞬間に何件使えているか」を知りたいだけの用途はこちらを使うこと
    /// — `resolvedURL(for:)` を全件に対して回すと、`.withoutMounting` を
    /// 付けていない解決がイジェクト済みのボリュームを**再マウントしてしまう**
    /// （実測済み、`08_インフラ_ファイル操作.md` §8.7.1 BM-5）。
    public func activeAccessCount() async -> Int {
        await ensureLoaded()
        return activeAccessURLs.count
    }

    /// 解決済みの URL。ボリューム未接続等でオフラインの場合は `nil` [SB-05]。
    ///
    /// **マウントは起こさない** [RG3-01][NV-91]。``BookmarkResolving/resolve(_:)``
    /// が `.withoutMounting` を既定にしているため、未接続のボリュームは
    /// 再マウントされずそのまま `nil` になる。
    ///
    /// - Note: ここには以前「`.withoutMounting` を付けずに解決するので
    ///   再マウントされることがある（1-17 で対処予定）」と書いてあったが、
    ///   **その対処は NV-91 で済んでおり、記述だけが取り残されていた**。
    ///   本プロジェクトが繰り返し踏んでいる「コメントと実装の食い違い」で、
    ///   しかも今回は**実装のほうが安全側**という向きだったため、
    ///   読んだ人が無用な回避策を足しかねない形になっていた。
    ///
    /// - Important: 相手が**マウント済みなのに応答しない**共有では解決が
    ///   ブロックし得るため、`FileIO` 経由で協調プールの外へ逃がしたうえ、
    ///   上限時間で待つのをやめる [NV6-05]。上限を超えた解決は「応答なし」
    ///   （＝ `nil`）として扱う。件数を数えるだけなら `activeAccessCount()` を
    ///   使うこと。
    public func resolvedURL(for folder: RegisteredFolder) async -> URL? {
        let resolution = await bookmarks.resolve(folder.bookmarkData, waitingAtMost: resolutionDeadline)
        guard case .resolved(let url, _) = resolution else { return nil }
        return url
    }

    // MARK: - 縮退状態の解決 [1-17、8章 §8.7.1]

    /// 全登録フォルダの現在の状態 [RG3-07]。
    ///
    /// ## 判定の順序が設計の要点 [RG3-01][BM-5]
    /// **ボリュームのマウント状態を、ブックマークを解決する「前」に見る。**
    /// 順序を逆にすると、未接続を判定するはずの処理がその判定の過程で
    /// ボリュームをマウントしてしまう——ネットワーク越しならそれは
    /// 「接続タイムアウト分のブロック」と「ユーザーが何もしていないのに出る
    /// 認証ダイアログ」を意味する。
    ///
    /// `resolve` は既に `.withoutMounting` が既定 [RG3-01] なので副作用自体は
    /// 塞がれているが、順序はそれでも守る価値がある——**未接続と分かっている
    /// 登録には 1 回も出て行かずに済む**し、`.offline` と `.missing` の区別は
    /// そもそもマウント状態を見なければ付かない（実測: イジェクトも完全削除も
    /// 等しく `NSCocoaErrorDomain code=4`）。
    ///
    /// ## 費用
    /// マウント表の読み出しは I/O 無し・1 回だけ。ブックマークの解決と実体の
    /// 問い合わせはどちらも**並行**かつ上限時間つきで、応答しないボリュームが
    /// あっても待ちは上限 1 回分で収まる。
    public func states() async -> [RegisteredFolderState] {
        await ensureLoaded()

        // ① マウント表を 1 回だけ写す。**どのファイルシステムにも触れない** [NV6-02]。
        let mounts = MountTable.current()
        let snapshot = folders

        // ② 未接続と分かっているものは解決を試みない。
        var offline: [UUID: RegisteredFolderStatus] = [:]
        var toResolve: [(id: UUID, data: Data)] = []
        for folder in snapshot {
            if let path = folder.lastKnownPath, mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path)) {
                offline[folder.id] = .offline(lastKnownPath: path)
            } else {
                toResolve.append((id: folder.id, data: folder.bookmarkData))
            }
        }

        // ③ 残りを並行に解決する（`.withoutMounting` ＋ 上限時間）。
        let resolutions = await bookmarks.resolveMany(toResolve, waitingAtMost: resolutionDeadline)

        // ④ 解決できた URL の実体を、まとめて 1 回の FileIO で問い合わせる。
        let resolvedURLs = resolutions.compactMapValues { resolution -> URL? in
            guard case .resolved(let url, _) = resolution else { return nil }
            return url
        }
        let probes = await Self.probe(resolvedURLs, waitingAtMost: resolutionDeadline)

        // ⑤ 分類する。
        var states: [UUID: RegisteredFolderStatus] = offline
        for folder in snapshot where states[folder.id] == nil {
            states[folder.id] = Self.classify(
                folder: folder,
                resolution: resolutions[folder.id],
                probe: probes[folder.id],
                mounts: mounts
            )
        }

        await rememberResolvedPaths(states)
        let nested = Self.nestedIDs(among: snapshot, states: states)

        // **解決している間に解除された登録は返さない。** 各 await では actor 再入が
        // 起こるため、`unregister` が割り込むとスナップショットには残っている。
        // そのまま返すと、消したはずの行がツリーに一度描かれてしまう。
        // 併せて、控えている場所が更新された可能性があるので**現在の値**を返す。
        return snapshot.compactMap { folder in
            guard let current = folders.first(where: { $0.id == folder.id }) else { return nil }
            return RegisteredFolderState(
                folder: current,
                status: states[folder.id] ?? .offline(lastKnownPath: current.lastKnownPath),
                isNested: nested.contains(folder.id)
            )
        }
    }

    /// 種別で絞った状態一覧。並びは ``folders(kind:)`` と同じ表示名順。
    public func states(kind: RegisteredFolderKind) async -> [RegisteredFolderState] {
        await states()
            .filter { $0.folder.kind == kind }
            .sorted { $0.folder.displayName.localizedStandardCompare($1.folder.displayName) == .orderedAscending }
    }

    /// 実体を見失った登録に、新しい場所を割り当て直す [RG3-04 の「場所を選び直す…」]。
    ///
    /// **登録 ID を保つのが要点。** 解除して登録し直すのとは違い、この ID に
    /// 紐づくもの（フェーズ1ではサムネイル非表示設定、フェーズ2ではラベル・
    /// 評価・カバー画像）がそのまま生き残る。
    ///
    /// 入れ子禁止 [RG-03][RG-04] とファイルシステム適合 [RG-08] は、新規登録と
    /// 同じように検査する——移し先が別の登録の中だったり、同一性を追跡できない
    /// ボリュームだったりしたら、そこを新しい住所にしてはいけない。
    /// **自分自身との入れ子は当然除く。**
    @discardableResult
    public func relocate(_ id: UUID, to url: URL) async throws -> RegistrationResult {
        await ensureLoaded()
        guard folders.contains(where: { $0.id == id }) else {
            throw RegisteredFolderError.notRegistered
        }
        let resolvedURL = url.resolvingSymlinksInPath() // [SL-07]
        // 新規登録とまったく同じ検査を通す [RG-03][RG-04][RG-08][NV-87][NV8-04]。
        // **自分自身は入れ子の比較から外す** — 外さないと、同じ場所を選び直した
        // だけで拒まれる。
        let warnings = try await validateDestination(resolvedURL, ignoringNestingWith: id)

        // **添字は await をまたいで持ち越さない。** 上の検査には最大で
        // 「ブックマーク解決の上限時間 ＋ ボリュームの実測」ぶんの await があり、
        // その間に actor 再入で `unregister` が割り込めば配列がずれる——
        // 持ち越すと**別の登録を書き換える**か範囲外で落ちる。ここで引き直す
        // （`rename`/`setThumbnailsAlwaysHidden` が await を挟まないのに対し、
        // この経路だけが構造的にこの危険を持つ）。
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw RegisteredFolderError.notRegistered
        }

        // 古い場所のセキュリティスコープを閉じてから差し替える。閉じ忘れると
        // 解除できないアクセスが残る［完全削除 FM-14 実装時のレビューで
        // 実際に見つかった形のリーク］。
        if let old = activeAccessURLs.removeValue(forKey: id) {
            old.stopAccessingSecurityScopedResource()
        }
        folders[index].bookmarkData = try bookmarks.makeBookmark(for: resolvedURL) // [RG-07]
        folders[index].lastKnownPath = resolvedURL.standardizedFileURL.path
        await activateAccessIfPossible(folders[index])
        try save()
        Log.sandbox.info("登録フォルダの場所を選び直しました: \(Log.path(resolvedURL))")
        return RegistrationResult(folder: folders[index], warnings: warnings)
    }

    /// 登録先として受け入れてよいかを検査し、**知らせるべきこと**を返す。
    ///
    /// `register` と `relocate` で**同じ実装を共有する**のが要点。以前は
    /// `relocate` が入れ子とファイルシステムだけを見てクラウド同期の検出
    /// [NV8-04] を欠いており、ネットワーク共有やクラウドへ移し替えても
    /// 警告が一切出なかった——「同じに見える操作に独立した実装経路ができ、
    /// 片方だけ直して取り残される」という、このコードベースが 1-12 の
    /// アプリ関連付けで実際に踏んだ形。
    private func validateDestination(
        _ resolvedURL: URL, ignoringNestingWith id: UUID? = nil
    ) async throws -> [RegistrationWarning] {
        try await checkNotNested(resolvedURL, ignoring: id)

        var warnings: [RegistrationWarning] = []
        switch try await volumeChecker.evaluate(resolvedURL) { // [RG-08][FS-01〜FS-05]
        case .rejected(let reason):
            throw RegisteredFolderError.unsupportedFileSystem(reason)
        case .eligible(let volumeWarnings):
            warnings = volumeWarnings // [FS-06] 提示は呼び出し側（UI）が行う
        }

        // **クラウド同期の配下かは、ボリュームからは分からない** — File Provider は
        // 起動ボリュームの UUID を返す（8章 §8.11.1）ので、`volumeChecker` の
        // 守備範囲の外にある。ここで一度だけ尋ねる [NV8-04][NV-98]。
        if let cloud = await CloudSyncLocation.detect(at: resolvedURL) {
            Log.fileOps.info(
                "クラウド同期の配下に登録します（provider=\(cloud.providerName ?? "不明")"
                    + " domain=\(cloud.domainIdentifier ?? "不明")）: \(Log.path(resolvedURL))"
            )
            warnings.append(.cloudSyncedLocation(provider: cloud.providerName))
        }
        return warnings
    }

    // MARK: 状態解決の内訳

    /// 解決できた URL の実体を問い合わせた結果。
    ///
    /// `private` にせず `internal` にしてあるのは、``classify(folder:resolution:probe:mounts:)``
    /// をテストから直接ぶつけるため。`.offline` は「ボリュームが外れている」
    /// 状況でしか起きず、実ストア経由では作り出せない（一時ディレクトリは
    /// 常にマウントされている）——`MountTable` を合成して純粋関数へ渡すのが
    /// 唯一まともに検証できる形である
    /// [`WindowState.relocateIfFolderVanished(knownToExist:)` と同じ理由]。
    struct FolderProbe: Sendable {
        let isDirectory: Bool
        /// [FS-08] 宣言値だけを見る。登録時の完全な検証（FS-03 の作成→移動→
        /// ID 再取得）は**書き込みを伴う**ので、状態解決のたびには回せない
        /// ［ユーザー判断: 宣言値だけを毎回見る］。ボリュームを別の
        /// ファイルシステムで再フォーマットされた、という実際に起こり得る
        /// 変化はこれで捉えられる。
        let supportsPersistentIDs: Bool?
        let fileSystemName: String?
    }

    /// 解決できた URL 群を**1 回の `FileIO` で**まとめて問い合わせる [NV6-02]。
    /// 1 件ずつ往復すると、登録が多いときにレーンを無駄に使う。
    private static func probe(
        _ urls: [UUID: URL], waitingAtMost limit: Duration
    ) async -> [UUID: FolderProbe] {
        guard !urls.isEmpty else { return [:] }
        do {
            return try await FileIO.perform(waitingAtMost: limit) {
                var result: [UUID: FolderProbe] = [:]
                for (id, url) in urls {
                    let values = try? url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .volumeSupportsPersistentIDsKey,
                        .volumeLocalizedFormatDescriptionKey,
                    ])
                    result[id] = FolderProbe(
                        isDirectory: values?.isDirectory ?? false,
                        supportsPersistentIDs: values?.volumeSupportsPersistentIDs,
                        fileSystemName: values?.volumeLocalizedFormatDescription
                    )
                }
                return result
            }
        } catch {
            // 上限を過ぎた。**問い合わせられなかっただけで「無い」ではない**
            // ので、`nil` を返して `classify` に「不明」として扱わせる。
            Log.sandbox.warning("登録フォルダの実体確認が \(limit.inSeconds) 秒以内に完了しません")
            return [:]
        }
    }

    /// 解決結果と実体の問い合わせから状態を決める。**純粋関数**（I/O 無し）に
    /// してあるので、テストから直接ぶつけられる。
    static func classify(
        folder: RegisteredFolder,
        resolution: BookmarkResolution?,
        probe: FolderProbe?,
        mounts: MountTable
    ) -> RegisteredFolderStatus {
        guard case .resolved(let url, _)? = resolution else {
            // **「実体が消えた」と言ってよい失敗かどうかを先に見る** [レビューで発見]。
            //
            // `.unresponsive`（マウントは残っているがサーバが上限時間内に
            // 答えない）と `.permissionDenied` は、**実体の有無について何も
            // 言っていない**。マウント表には載ったままなので、これらを下の
            // 判定へ流すと `.missing` になり——応答の遅い NAS 上の健全な
            // ライブラリに「見つかりません」と表示して、ユーザーに解除を
            // 促してしまう。1-17 がまさに無くそうとしている取り違えである。
            if case .offline(let reason)? = resolution,
               reason == .unresponsive || reason == .permissionDenied {
                return .offline(lastKnownPath: folder.lastKnownPath)
            }

            // ここから先は「実体を探しに行って見つからなかった」失敗。
            // **イジェクトと完全削除は同じエラーになる**ので
            // （実測: どちらも `NSCocoaErrorDomain code=4`）、マウント表で分ける。
            guard let path = folder.lastKnownPath else {
                // まだ一度も解決できていない登録。どちらとも断定できないので
                // **`.offline` に倒す** — 「見つかりません」と言って解除を
                // 促してしまうより、「接続すれば戻ります」と言うほうが害が小さい
                // （`MountTable.isOnAnUnmountedVolume` が判定不能を `true` に
                // 倒しているのと同じ向き）。
                return .offline(lastKnownPath: nil)
            }
            return mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path))
                ? .offline(lastKnownPath: path)
                : .missing(lastKnownPath: path)
        }

        // ゴミ箱の中か [BM-2][RG3-03]。**実在確認より先に見る** — ゴミ箱の中でも
        // 実体はあるので、順序を逆にすると `.online` として通ってしまう。
        if TrashLocation.isInTrash(url) {
            return .inTrash(url: url)
        }

        guard let probe else {
            // 問い合わせが上限に間に合わなかった。解決自体は成功しているので
            // `.online` として扱う——ここで縮退させると、応答の遅い共有が
            // 一時的に使えなくなる。
            return .online(url: url)
        }
        guard probe.isDirectory else {
            // 解決できたのにディレクトリでない。ファイルへ置き換えられた等。
            return .missing(lastKnownPath: url.path)
        }
        if probe.supportsPersistentIDs == false { // [FS-08] `nil`（不明）では縮退させない
            return .unsupportedFileSystem(url: url, fileSystemName: probe.fileSystemName)
        }
        return .online(url: url)
    }

    /// 解決できた登録の `lastKnownPath` を更新する。**値が変わったときだけ保存する**
    /// ——状態解決はツリーの更新のたびに走るので、毎回書くと JSON を延々と
    /// 書き直すことになる。
    private func rememberResolvedPaths(_ states: [UUID: RegisteredFolderStatus]) async {
        var changed = false
        for (id, status) in states {
            // **ゴミ箱の中の場所は覚えない** [実機検証で気づいた]。覚えると、
            // ゴミ箱を経て完全削除された登録の「最後に分かっている場所」が
            // `…/.Trashes/501/名前` になり、①`.missing` の表示がゴミ箱の
            // パスになる ②「場所を選び直す…」パネルがそこを起点に開こうとして
            // 失敗し、まったく無関係なホームから開く（実機で実際にそうなった）。
            // 覚えておきたいのは**健全だったときの場所**なので、ここは飛ばす。
            // `.inTrash` 自身は `status` が URL を持っているので「Finder で表示」
            // には困らない。
            if case .inTrash = status { continue }
            guard let url = status.resolvedURL else { continue }
            let path = url.standardizedFileURL.path
            guard let index = folders.firstIndex(where: { $0.id == id }) else { continue }
            guard folders[index].lastKnownPath != path else { continue }
            folders[index].lastKnownPath = path
            changed = true
        }
        guard changed else { return }
        do {
            try save()
        } catch {
            // 覚え直せなくても状態解決そのものは成立している（次回また解決して
            // 同じ値に落ち着く）ので、ここで操作を失敗させない。
            Log.sandbox.warning("登録フォルダの最終解決パスを保存できません: \(error.localizedDescription)")
        }
    }

    /// 外部での移動によって入れ子禁止が事後に破れた登録 [RG3-05]。
    ///
    /// **関係する両方を返す。** どちらが「悪い」わけでもなく、対になって
    /// いることが問題なので、片方だけに警告を出すと直しようがない。
    static func nestedIDs(
        among folders: [RegisteredFolder], states: [UUID: RegisteredFolderStatus]
    ) -> Set<UUID> {
        // 場所が分かっているものだけが対象。オフライン・消失は比較できない。
        let located: [(id: UUID, path: String)] = folders.compactMap { folder in
            guard let url = states[folder.id]?.resolvedURL else { return nil }
            return (id: folder.id, path: url.standardizedFileURL.path)
        }
        var result: Set<UUID> = []
        for outer in 0..<located.count {
            for inner in (outer + 1)..<located.count where
                pathsOverlap(located[outer].path, located[inner].path) {
                result.insert(located[outer].id)
                result.insert(located[inner].id)
            }
        }
        if !result.isEmpty {
            Log.sandbox.warning("登録フォルダの入れ子禁止が外部での移動により破れています: \(result.count) 件")
        }
        return result
    }

    /// 同一、または一方が他方の祖先か。**区切りまで含めて**比べる
    /// ——素の `hasPrefix` だと `/a/Comics` が `/a/ComicsOld` に一致する。
    static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    /// 登録の結果。**警告も一緒に返す** [NV-87]。
    ///
    /// 以前はここで `case .eligible: break` として捨てていた（コメントには
    /// 「提示は呼び出し側の責務」と書いてありながら、呼び出し側へ渡す口が
    /// 無かった）。`VolumeCapability.isReadOnly` が「計算されていたのに誰も
    /// 読んでいなかった」のと同じ形の抜け。
    public struct RegistrationResult: Sendable {
        public let folder: RegisteredFolder
        /// ネットワークボリュームである等、**登録は通るが知らせるべきこと**
        /// [FS-06]。空なら何も出さない。
        public let warnings: [RegistrationWarning]
    }

    @discardableResult
    public func register(
        url: URL, kind: RegisteredFolderKind, displayName: String?
    ) async throws -> RegistrationResult {
        await ensureLoaded()
        let resolvedURL = url.resolvingSymlinksInPath() // [SL-07]
        // この先の各 await 中は actor 再入が起こり得るため、同時に走る
        // `register` 同士では「チェック後・追加前」に相手の追加が割り込む
        // 余地がある。登録は UI のパネル経由で 1 件ずつしか起きず、この競合は
        // `volumeChecker.evaluate` の await があった従来から同型で許容している
        // ため、ここでは防がない [NV6-05 の async 化に伴う注記]。
        let warnings = try await validateDestination(resolvedURL)

        let bookmarkData = try bookmarks.makeBookmark(for: resolvedURL) // [RG-07]
        let folder = RegisteredFolder(
            kind: kind, displayName: displayName ?? resolvedURL.lastPathComponent, bookmarkData: bookmarkData,
            // 登録した時点で場所は分かっているので、最初からここに控える [1-17]。
            // 以後は解決に成功するたび `rememberResolvedPaths` が追従させる。
            lastKnownPath: resolvedURL.standardizedFileURL.path
        )
        folders.append(folder)
        await activateAccessIfPossible(folder)
        try save()
        if !warnings.isEmpty {
            Log.fileOps.info("登録しました（警告 \(warnings.count) 件）: \(Log.path(resolvedURL))")
        }
        return RegistrationResult(folder: folder, warnings: warnings)
    }

    /// [RG-06 の簡易版] フェーズ1にはラベルドメインが無いため「削除するか
    /// 保持するか」の選択肢自体が意味を持たない。登録レコードを削除するのみ。
    public func unregister(_ id: UUID) async throws {
        await ensureLoaded()
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        // 実体が既に消えていてもスコープを確実に閉じられるよう、ブックマークの
        // 再解決ではなく登録 ID から引く（`activeAccessURLs` のコメント参照）。
        if let url = activeAccessURLs.removeValue(forKey: folder.id) {
            url.stopAccessingSecurityScopedResource()
        }
        folders.removeAll { $0.id == id }
        try save()
    }

    /// `urls` を完全削除すると実体が失われる登録フォルダを列挙する
    /// [完全削除 FM-14 の事前確認用]。対象そのものが登録フォルダである場合と、
    /// 対象が登録フォルダの祖先である（＝配下ごと消える）場合の両方を拾う。
    ///
    /// **解決済みのパスも一緒に返す。** 削除後にはブックマークを解決できず
    /// 「どの登録が該当したか」を再判定できないため、呼び出し側は削除の前に
    /// この結果を保持しておく必要がある（`unregisterAll(ids:)` 参照）。
    ///
    /// 比較は `URL` 同士の `==` ではなくパス文字列で行う — 末尾スラッシュの
    /// 有無やシンボリックリンクの解決状態で表現が揺れるため
    /// [`SessionState.cutURLs` で実際に踏んだ問題と同じ理由]。
    public func registrationsInvalidated(byDeleting urls: [URL]) async -> [InvalidatedRegistration] {
        await ensureLoaded()
        let deletedPaths = urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        // 解決の await 中に actor 再入で `folders` が変わっても一貫した結果を
        // 返せるよう、スナップショットに対して照合する [NV6-05]。
        let snapshot = folders
        let resolutions = await bookmarks.resolveMany(
            snapshot.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        return snapshot.compactMap { folder in
            guard case .resolved(let folderURL, _)? = resolutions[folder.id] else { return nil }
            let folderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
            let isDoomed = deletedPaths.contains { deleted in
                folderPath == deleted || folderPath.hasPrefix(deleted + "/")
            }
            guard isDoomed else { return nil }
            return InvalidatedRegistration(folder: folder, resolvedPath: folderPath)
        }
    }

    /// 完全削除で実体を失った登録を強制的に解除する [ユーザー要望: 完全削除を
    /// 実行することになった場合はライブラリ／テンポラリの登録も強制解除する]。
    ///
    /// **対象は削除の実行「前」に `registrationsInvalidated(byDeleting:)` で
    /// 捉えておき、その ID をここへ渡すこと。** 登録の照合は
    /// Security-Scoped Bookmark の解決に依存するため、実体が消えた後では
    /// どの登録が該当したのかを判定できなくなる。逆に解除を削除より先に
    /// 行うとアクセススコープが閉じて削除自体が権限エラーになるため、
    /// 「先に調べ、後で解除する」というこの順序でなければならない。
    public func unregisterAll(ids: [UUID]) async {
        for id in ids {
            try? await unregister(id)
        }
    }

    /// [RG-05] 実フォルダ名とは別の表示名に変更する。
    public func rename(_ id: UUID, to displayName: String) async throws {
        await ensureLoaded()
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].displayName = displayName
        try save()
    }

    /// この登録フォルダの配下でサムネイルを常に非表示にするか [DS-04]。
    /// 未登録の ID を渡した場合は何もしない（`rename` と同じ方針）。
    public func setThumbnailsAlwaysHidden(_ hidden: Bool, for id: UUID) async throws {
        await ensureLoaded()
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].thumbnailsAlwaysHidden = hidden
        try save()
    }

    /// 初回アクセス時に一度だけ永続化データを読み込み、ブックマークへの
    /// アクセスを開始する。呼び出し元（アプリ起動時の明示呼び出しと、
    /// `FolderTreePane` 側の初回表示）のどちらが先に到達しても安全なように、
    /// すべての公開メソッドの先頭でこれを呼ぶ。
    ///
    /// ブックマーク解決の await 中は actor 再入が起こるため、「読み込み中」を
    /// `Task` としてメモ化し、後から到達した呼び出しは同じ `Task` を待つ
    /// [NV6-05]。単なる `Bool` フラグだと、2 番目の呼び出しが読み込み完了前の
    /// 空の `folders` を見てしまう。
    private func ensureLoaded() async {
        if loadTask == nil {
            loadTask = Task { await performInitialLoad() }
        }
        await loadTask?.value
    }

    private func performInitialLoad() async {
        load()
        // 全登録を**並行に**解決する [NV6-05]。逐次だと、サーバ不在時の
        // 起動待ちが「登録件数 × 上限時間」になってしまう。
        let resolutions = await bookmarks.resolveMany(
            folders.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        for folder in folders {
            activateAccess(folder, resolution: resolutions[folder.id] ?? .offline(reason: .invalidBookmark))
        }
        Log.sandbox.info(
            "登録フォルダを読み込みました: ライブラリ \(folders.count { $0.kind == .library }) 件 / テンポラリ \(folders.count { $0.kind == .temporary }) 件 / アクセス開始 \(activeAccessURLs.count) 件"
        )
    }

    private func activateAccessIfPossible(_ folder: RegisteredFolder) async {
        let resolution = await bookmarks.resolve(folder.bookmarkData, waitingAtMost: resolutionDeadline)
        activateAccess(folder, resolution: resolution)
    }

    private func activateAccess(_ folder: RegisteredFolder, resolution: BookmarkResolution) {
        guard case .resolved(let url, _) = resolution else {
            // 実体を失った登録は「アクセス権がありません」とは別の縮退状態
            // （ボリューム未接続／ゴミ箱／完全削除）[SB-05][1-17]。UI では
            // グレーアウト行として現れるだけなので、原因追跡のためログには
            // 必ず残す。
            // 解決できないので絶対パスが無い。表示名は書き出し時に匿名化
            // されるよう印を付ける [LG2-06]。
            Log.sandbox.warning(
                "登録フォルダのブックマークを解決できません: \(Log.redactable(folder.displayName)) (\(folder.kind))"
            )
            return
        }
        if url.startAccessingSecurityScopedResource() {
            activeAccessURLs[folder.id] = url
            Log.sandbox.debug("登録フォルダのアクセスを開始: \(Log.path(url))")
        } else {
            Log.sandbox.warning("登録フォルダのセキュリティスコープを開始できません: \(Log.path(url))")
        }
    }

    /// [RG-03][RG-04] 既存の登録フォルダ（ライブラリ・テンポラリ双方）との
    /// 祖先・子孫関係、および同一フォルダの二重登録を禁止する。
    ///
    /// - Parameter ignoring: 比較から外す登録。「場所を選び直す…」
    ///   （`relocate(_:to:)`）では**自分自身**を外す必要がある
    ///   ——外さないと、同じ場所を選び直しただけで「入れ子です」と拒まれる。
    private func checkNotNested(_ candidate: URL, ignoring: UUID? = nil) async throws {
        let candidatePath = candidate.standardizedFileURL.path
        let snapshot = folders.filter { $0.id != ignoring }
        let resolutions = await bookmarks.resolveMany(
            snapshot.map { (id: $0.id, data: $0.bookmarkData) }, waitingAtMost: resolutionDeadline
        )
        for resolution in resolutions.values {
            guard case .resolved(let existingURL, _) = resolution else { continue }
            if Self.pathsOverlap(candidatePath, existingURL.standardizedFileURL.path) {
                throw RegisteredFolderError.nestedRegistration
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let decoded = try? JSONDecoder().decode([RegisteredFolder].self, from: data) else {
            // デコードに失敗したまま `folders = []` として処理を続けると、次に
            // 何か1件でも登録・解除・改名をした瞬間の `save()` が壊れた内容
            // ごと上書きしてしまい、以前登録していたライブラリ／テンポラリ
            // フォルダがすべて復元不能になる [フェーズ1完了時の監査で追加、
            // `VolumeAccessStore.load()` と同じ対策]。元ファイルには触れず
            // 隣へ退避してから空の状態で続行し、手動での調査・復旧の余地を
            // 残す。
            let corruptBackup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: corruptBackup)
            Log.sandbox.error(
                "登録フォルダの永続化ファイルを読めません。\(corruptBackup.path) へ退避し、登録なしで続行します"
            )
            return
        }
        folders = decoded
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(folders)
        try data.write(to: storageURL, options: .atomic)
    }
}
