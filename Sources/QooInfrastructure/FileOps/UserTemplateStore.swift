//
//  ユーザー定義テンプレートの保管 [LT-02][LT-06]。
//
//  ## なぜ DB ではなく Application Support の JSON か［ユーザー判断、2026-09-04］
//  テンプレートは**ライブラリが 1 つも無くても要る**もので（登録ウィザードの
//  入口がそれ）、現に `LibraryServices.bootstrap` はプリセットを**ストアと
//  独立に**読んでいる——ストアが開けなくても型の一覧は見せられる、という
//  性質を保つ。`libraryType` テーブルは「ライブラリごとの型」であって
//  「新規登録に使える雛形の一覧」ではなく、登録解除しても行が残る既知の
//  性質があるので、雛形と残骸が混ざる。
//
//  作法は `RegisteredFolderStore` / `VolumeAccessStore` と同じ——`actor`、
//  全公開メソッドの先頭で `ensureLoaded()`、`.atomic` 書き込み、壊れた
//  ファイルは**消さずに隣へ退避**して空で続行する。
//
//  **`FileOps/` に置いているのは `FileManager` の変更系 API を使うため** [B-10]
//  （`RegisteredFolderStore` と同じ理由・同じ場所）。アプリ内部の設定ファイル
//  なので期待変更台帳・Undo の対象外。
//
import Foundation
import QooKit

public enum UserTemplateStoreError: Error, Equatable, Sendable {
    /// 新しいアプリが書いた文書。**黙って壊しながら読まない** [LT-06]。
    case documentTooNew(schemaVersion: Int)
    /// JSON として読めない。
    case unreadableDocument
}

/// 取り込みの結果 [LT-06]。
///
/// **何件入って何件を何の理由で弾いたかを必ず返す。** 黙って一部だけ入る
/// のが、この種の機能でいちばん報告されている壊れ方（OrcaSlicer の
/// 「silent import failures, misleading errors」）。
public struct UserTemplateImportOutcome: Sendable, Equatable {
    public struct Rejection: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// 名前が空。一覧で見分けが付かないものは入れない。
            case emptyName
        }
        public var name: String
        public var reason: Reason

        public init(name: String, reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    public var added: [UserTemplate]
    public var rejections: [Rejection]

    public init(added: [UserTemplate] = [], rejections: [Rejection] = []) {
        self.added = added
        self.rejections = rejections
    }
}

public actor UserTemplateStore {

    public static let shared = UserTemplateStore()

    private let storageURL: URL
    private var didLoad = false
    private var stored: [UserTemplate] = []

    /// - Parameter storageURL: 置き場所。既定は
    ///   `~/Library/Application Support/qooLibrary/userTemplates.json`。
    ///   **テストは一時ディレクトリを渡すこと。**
    ///
    /// **`swift test` 中は既定そのものを一時ディレクトリへ振り替える**
    /// ——`DefaultUserCoverStore` / `DiagnosticLog` と同じ二重の防御。
    /// 注入を忘れた 1 箇所が開発機の実テンプレートを書き換えるのは、
    /// 失っても再生成できない種類のデータなので取り返しがつかない。
    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else if RuntimeEnvironment.isRunningTests {
            self.storageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooLibrary-tests/userTemplates.json")
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.storageURL = appSupport
                .appendingPathComponent("qooLibrary/userTemplates.json")
        }
    }

    // MARK: - 読み

    /// 保存順に返す。**並べ替えない**——利用者が足した順が一覧の順になる
    /// （名前順にすると改名で並びが飛ぶ）。
    public func templates() -> [UserTemplate] {
        ensureLoaded()
        return stored
    }

    public func template(id: UUID) -> UserTemplate? {
        ensureLoaded()
        return stored.first { $0.id == id }
    }

    // MARK: - 書き

    /// 追加または上書き（`id` で同定）。
    @discardableResult
    public func save(_ template: UserTemplate) throws -> UserTemplate {
        ensureLoaded()
        if let index = stored.firstIndex(where: { $0.id == template.id }) {
            stored[index] = template
        } else {
            stored.append(template)
        }
        try write()
        return template
    }

    /// 削除 [★14: 常に消せる]。
    ///
    /// **そのテンプレートから登録したライブラリがあっても消せる。** [LT-03] に
    /// より登録時に設定はライブラリ側へ写るので、消しても既存ライブラリは
    /// 無傷（ユーザー定義は `presetKey` を持たないので参照も完全に切れている）。
    public func remove(id: UUID) throws {
        ensureLoaded()
        stored.removeAll { $0.id == id }
        try write()
    }

    /// JSON バックアップからの復元 [★8]。**併合する（上書きも削除もしない）。**
    ///
    /// 丸ごと入れ替えにしない理由は 2-16 で決めた原則と同じ——
    /// **「消せる取り込み」は、復旧のつもりの操作で手元のものを失う経路になる。**
    ///
    /// `importDocument` と違い**身元をそのまま使う**ので、同じバックアップを
    /// 2 度取り込んでも増えない（冪等）。あちらは「他人が書き出した文書を
    /// 自分の一覧へ足す」、こちらは「自分の状態を戻す」——目的が違う。
    ///
    /// - Returns: 実際に足した件数。
    @discardableResult
    public func merge(_ templates: [UserTemplate]) throws -> Int {
        ensureLoaded()
        let known = Set(stored.map(\.id))
        let incoming = templates.filter { !known.contains($0.id) }
        guard !incoming.isEmpty else { return 0 }
        stored.append(contentsOf: incoming)
        try write()
        return incoming.count
    }

    // MARK: - 入出力 [LT-06]

    /// 書き出す文書を組み立てる。`ids` が `nil` なら全件。
    public func exportDocument(ids: Set<UUID>? = nil) -> UserTemplateDocument {
        ensureLoaded()
        let selected = ids.map { set in stored.filter { set.contains($0.id) } } ?? stored
        return UserTemplateDocument(templates: selected)
    }

    /// 文書を取り込む [LT-06]。
    ///
    /// **併合も上書きもしない——常に新しい身元で足す**［★22 の判断］。
    /// 同じ文書を 2 度読めば 2 件になるが、それは一覧で見えて消せる。
    /// 名前や id が一致した既存を書き換える形にすると、**取り込みが
    /// 「消せる操作」になる**——復旧のつもりの操作で手元の編集を失う。
    public func importDocument(_ document: UserTemplateDocument,
                               now: Date = Date()) throws -> UserTemplateImportOutcome {
        guard document.isReadable else {
            throw UserTemplateStoreError.documentTooNew(schemaVersion: document.schemaVersion)
        }
        ensureLoaded()
        var outcome = UserTemplateImportOutcome()
        for incoming in document.templates {
            let name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                outcome.rejections.append(.init(name: incoming.name, reason: .emptyName))
                continue
            }
            let copy = UserTemplate(id: UUID(), name: name, version: incoming.version,
                                    createdAt: incoming.createdAt, updatedAt: now,
                                    settings: incoming.settings)
            stored.append(copy)
            outcome.added.append(copy)
        }
        if !outcome.added.isEmpty { try write() }
        return outcome
    }

    /// ファイルから読んで取り込む [LT-06]。
    public func importDocument(at url: URL,
                               now: Date = Date()) throws -> UserTemplateImportOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UserTemplateStoreError.unreadableDocument
        }
        guard let document = try? UserTemplateDocument.makeDecoder()
            .decode(UserTemplateDocument.self, from: data)
        else {
            throw UserTemplateStoreError.unreadableDocument
        }
        return try importDocument(document, now: now)
    }

    // MARK: - 永続化

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: storageURL) else {
            // 初回起動（ファイルが無い）は正常。**在るのに読めない**場合だけ
            // 記録する——このあと 1 件でも保存すると `write()` が空で上書きし、
            // 「テンプレートが勝手に消えた」と見える事象の唯一の手掛かりになる。
            if FileManager.default.fileExists(atPath: storageURL.path) {
                Log.fileOps.error(
                    "ユーザー定義テンプレートを読めません: \(Log.path(storageURL))")
            }
            return
        }
        guard let document = try? UserTemplateDocument.makeDecoder()
                .decode(UserTemplateDocument.self, from: data),
              document.isReadable else {
            // **消さずに隣へ退避する**（`RegisteredFolderStore` と同じ対策）。
            // 空で続行して上書きすると、手で作ったテンプレートが復旧不能になる。
            let retired = storageURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "\(storageURL.lastPathComponent).corrupt-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: storageURL, to: retired)
            Log.fileOps.error(
                "ユーザー定義テンプレートを読めません。\(retired.path) へ退避し、0 件で続行します")
            return
        }
        stored = document.templates
    }

    private func write() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try UserTemplateDocument.makeEncoder()
            .encode(UserTemplateDocument(templates: stored))
        try data.write(to: storageURL, options: .atomic)
    }
}
