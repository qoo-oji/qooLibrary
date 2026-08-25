//
//  フォルダ表示モードでのブックフォルダの扱い [IF-17][IF-18][BF-08][BF-09]。
//
//  ブックフォルダは「サブフォルダを持たず、直下に対象拡張子ファイルが 0 件かつ
//  画像ファイルが 1 件以上」のフォルダ [IF-01]。**ライブラリ表示モードでは既に
//  1 冊として 1 行に出ている**ので、この型が要るのはフォルダ表示モードだけ
//  ——あちらでは通常のフォルダとして並ぶため、印が無いと見分けが付かない。
//
//  判定の出どころは **DB の `isBookFolder`**。その場で規則を計算すると
//  フォルダの数だけ列挙が要り、費用が釣り合わない。
//
//  `LabelFilterModel` と同じ理由でこの層に置く——アプリターゲットのコードは
//  `swift test` から触れないので、規則を View に書くと固定できない。
//
import Foundation
import Observation
import QooKit

@MainActor
@Observable
public final class BookFolderIndex {
    /// 現在フォルダ直下のブックフォルダの名前 [IF-17]。
    public private(set) var names: Set<String> = []
    /// このライブラリではブックフォルダを関連付けアプリで開くか [IF-18]。
    public private(set) var opensWithApp = false

    /// 古い結果を捨てるための世代。条件が変わっても走っている問い合わせは
    /// 止まらないので、番号が合わないものは無視する（`LibraryContentModel` と
    /// 同じ形）。
    private var generation = 0

    public init() {}

    /// 読み込む。
    ///
    /// **`library` が `nil`（ボリューム経由・ライブラリ機能が無効・DB 未準備）
    /// なら空にする** [LF-01 と同じ判断]——同じ実フォルダでも、ライブラリの
    /// 入口から入ったときだけライブラリ由来の情報を見せる。評価もラベルも
    /// カバーもそう扱っており、ここだけ例外にすると一貫しない。
    public func load(library: LibrarySummary?, relativePath: String?,
                     services: LibraryServices) async {
        generation &+= 1
        let mine = generation
        guard let library, let relativePath, services.isReady else {
            names = []
            opensWithApp = false
            return
        }
        do {
            let found = try await services.bookFolderChildNames(
                libraryID: library.id, relativePath: relativePath)
            let opens = try await services.opensBookFolderWithApp(libraryID: library.id)
            guard mine == generation else { return }
            names = found
            opensWithApp = opens
        } catch {
            guard mine == generation else { return }
            // **取り消しは失敗ではない**（他のモデルと同じ扱い）。
            guard !CommandStack.isCancellation(error) else { return }
            // 引けなかったときは印を出さない。**通常のフォルダとして描くのが
            // 安全側**——ブックフォルダに印が付かないのは見た目の欠落だが、
            // 通常のフォルダに印が付くと「中へ降りられないはず」と誤らせる。
            names = []
            opensWithApp = false
        }
    }

    public func clear() {
        generation &+= 1
        names = []
        opensWithApp = false
    }

    /// この項目にブックフォルダの印を出すか [IF-17]。
    ///
    /// **フォルダにしか出さない。** 名前だけで照合すると、同名のファイルが
    /// 同じフォルダにあるとき（`作品A` というフォルダと `作品A` というファイル
    /// は共存できる）ファイルの側にも印が付く。
    nonisolated public static func indicatesBookFolder(name: String, isDirectory: Bool,
                                                       in names: Set<String>) -> Bool {
        isDirectory && names.contains(name)
    }
}
