import CoreGraphics
import Foundation
import ImageIO
import QooKit
import UniformTypeIdentifiers

/// ユーザーが指定したカバー画像の**複製**を持つ [CV-06][CV-08][TH-04][CL-05]。
///
/// ## 自動サムネイルのキャッシュとは別物
/// `CoverImageCache`（`covers/v2/`）は**捨ててよい**——鍵は
/// `FileContentStamp`（内容の版）で、消えても次に必要になったとき作り直せる。
/// だから上限 [IV-09] で古いものから削り、環境設定の「キャッシュを空にする」で
/// 全部捨てられる。
///
/// こちらは**捨ててはいけない**。元画像は外部にあり、しかも消えていることが
/// あるので [CV-08]、複製を失うとカバーは二度と復元できない。同じ場所に置くと
/// `prune`/`clear` が巻き添えで消してしまうため、ディレクトリを分けてある。
///
/// ## 鍵は `FileID` ではなく、保存のたびに振り直す名前
/// `managedFile` の rowid は `AUTOINCREMENT` を付けていない [T-03 の決定③] ので
/// 削除後に再利用されうる。`FileID` から複製の名前を**導出**すると、行が消えて
/// 別のファイルが同じ rowid を得たときに他人のカバーを拾う（`FileContentStamp`
/// を導入した理由 [TH-08] とまったく同じ形の事故）。名前は保存のたびに新しい
/// UUID を振り、**DB の `coverImageRef` に書かれたものだけを引く**——参照が
/// 残っていなければ、その複製は誰のものでもない。
///
/// ## 差し替え・「既定に戻す」で複製を消さない
/// どちらも ⌘Z で戻せる [UD-01] ので、その場で消すと**取り消した先に実体が
/// 無い**という状態を作る。捨てるのは起動時の掃除（`purgeUnreferenced`）だけ
/// ——`CommandStack` はメモリのみで再起動をまたがないため、そのとき参照されて
/// いない複製は誰も戻せない [`SecureExtractor.cleanupResidualStaging()` と
/// 同じ位置づけ]。
///
/// `FileManager` の変更系 API を使うため `FileOps/` 配下に置いている
/// [B-10。`CoverImageCache`/`QuickLookCoverStore` と同じ設計判断: アプリ内部の
/// 保管領域で、期待変更台帳・Undo の対象外]。
public protocol UserCoverStoring: Sendable {
    /// 参照から複製の場所を求める。**存在するかは呼び出し側が判定する**
    /// （複製が失われていても表示は既定へ落とすだけで済ませたいため）。
    func url(forRef ref: String, libraryUUID: UUID) -> URL
    /// 画像データを複製として保存し、DB に書く参照を返す [CV-06]。
    /// **画像として解釈できないデータは拒否する** — 書いてから気づくと、
    /// 参照だけが残って表示が既定へ落ちる原因の分からない状態になる。
    func store(_ data: Data, libraryUUID: UUID) throws -> String
    /// いま参照されていない複製を捨てる。**起動時に一度だけ呼ぶ。**
    /// - Parameter referenced: ライブラリ UUID → そのライブラリが参照している名前。
    ///   ここに現れないライブラリのディレクトリは丸ごと捨てる（登録解除・
    ///   ライブラリ削除の後始末を兼ねる）。
    func purgeUnreferenced(_ referenced: [UUID: Set<String>]) async
    /// そのライブラリの複製をすべて捨てる（ライブラリを消したとき）。
    func removeAll(libraryUUID: UUID) async
    func totalSize() async -> Int64
}

public enum UserCoverStoreError: Error, Equatable {
    /// 画像として読めなかった [CV-05 で選ばれるのは任意のファイルなので起こる]。
    case notAnImage
}

public struct DefaultUserCoverStore: UserCoverStoring {
    public static let shared = DefaultUserCoverStore()

    private let baseDirectory: URL

    /// テストでは独立した一時ディレクトリを渡せる（`DefaultCoverImageCache` と
    /// 同じ設計判断）。
    ///
    /// **`swift test` 中は既定の場所も一時ディレクトリへ振り替える**
    /// [`DiagnosticLog` と同じ防御]。ここは「捨ててはいけない」保管領域なので、
    /// 注入を忘れた 1 箇所が開発機の実データを書き換える・消すことになる
    /// ——注入に頼らず、既定そのものを安全側にしておく。
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if RuntimeEnvironment.isRunningTests {
            self.baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qooLibrary-tests/usercovers", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport
                .appendingPathComponent("qooLibrary/usercovers", isDirectory: true)
        }
    }

    public func url(forRef ref: String, libraryUUID: UUID) -> URL {
        directory(for: libraryUUID).appendingPathComponent(ref, isDirectory: false)
    }

    public func store(_ data: Data, libraryUUID: UUID) throws -> String {
        guard let ext = Self.filenameExtension(of: data) else {
            throw UserCoverStoreError.notAnImage
        }
        // **元の拡張子を保つ** [TH-04]。PNG へ焼き直すと、可逆でない変換
        // （JPEG → PNG の肥大、アニメーション GIF の 1 コマ化）が起きる。
        let ref = "\(UUID().uuidString).\(ext)"
        let directory = directory(for: libraryUUID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(ref, isDirectory: false),
                       options: .atomic)
        return ref
    }

    public func purgeUnreferenced(_ referenced: [UUID: Set<String>]) async {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil) else { return }
        for directory in directories {
            guard let uuid = UUID(uuidString: directory.lastPathComponent) else {
                // 見覚えのない名前。**触らない** — こちらが作ったものだと
                // 確かめられないものを消すと、取り違えたときに取り返しがつかない。
                continue
            }
            guard let refs = referenced[uuid] else {
                // このライブラリはもう DB に無い（登録解除・削除された）。
                try? fm.removeItem(at: directory)
                continue
            }
            let files = (try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where !refs.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }

    public func removeAll(libraryUUID: UUID) async {
        try? FileManager.default.removeItem(at: directory(for: libraryUUID))
    }

    public func totalSize() async -> Int64 {
        // **同期ヘルパーへ退避する** — `NSDirectoryEnumerator` の `for-in` は
        // async 文脈から使えない（`makeIterator` が unavailable）。
        Self.totalSize(of: baseDirectory)
    }

    private static func totalSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func directory(for libraryUUID: UUID) -> URL {
        baseDirectory.appendingPathComponent(libraryUUID.uuidString, isDirectory: true)
    }

    /// データ自身が名乗る形式から拡張子を決める [`QuickLookCoverStore` と同じ理由:
    /// 選ばれたファイルの拡張子は実体と食い違うことがある]。
    static func filenameExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        return type.preferredFilenameExtension
    }
}
