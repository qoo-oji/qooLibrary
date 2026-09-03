//
//  バックアップのポート [A-02][RP2-01]。実装は `QooPersistence`。
//
import Foundation

/// 書き出す範囲 [IE-02]。
public enum BackupScope: Sendable, Equatable {
    /// DB 上のすべてのライブラリ。
    case everything
    /// 指定したライブラリだけ。
    case libraries([LibraryID])
}

/// 取り込みの計画 [IE-11][JS-06]。
///
/// **実行前に必ずこれを見せて承認を得る。** 取り込みは既存のラベル・評価を
/// 書き換えるので、「何件が増え、何件が変わり、何件が取り込まれないのか」を
/// 見ないまま押させない。
public struct ImportPlan: Sendable, Equatable {
    public struct LibraryChange: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            /// 同一性キーが一致するライブラリが DB にある。中身を重ねる。
            case update
            /// DB に無い。**取り込まない**（理由は ``BackupRepository`` の注記）。
            case missing
        }
        public var id: String { identityKey }
        public var identityKey: String
        public var displayName: String
        public var kind: Kind
        /// 文書にあるが DB に無いファイル。**行は作らない**（下記の注記）。
        public var filesMissing: Int
        /// 値を書き戻すファイル。
        public var filesUpdated: Int
        public var fieldsAdded: Int
        public var labelsAdded: Int
        public var fileLabelsAdded: Int

        public init(identityKey: String, displayName: String, kind: Kind,
                    filesMissing: Int, filesUpdated: Int,
                    fieldsAdded: Int, labelsAdded: Int, fileLabelsAdded: Int) {
            self.identityKey = identityKey
            self.displayName = displayName
            self.kind = kind
            self.filesMissing = filesMissing
            self.filesUpdated = filesUpdated
            self.fieldsAdded = fieldsAdded
            self.labelsAdded = labelsAdded
            self.fileLabelsAdded = fileLabelsAdded
        }
    }

    public var libraries: [LibraryChange]

    public init(libraries: [LibraryChange]) {
        self.libraries = libraries
    }

    public var isEmpty: Bool { libraries.isEmpty }
    public var filesUpdated: Int { libraries.reduce(0) { $0 + $1.filesUpdated } }
    public var filesMissing: Int { libraries.reduce(0) { $0 + $1.filesMissing } }
    public var labelsAdded: Int { libraries.reduce(0) { $0 + $1.labelsAdded } }
    public var fileLabelsAdded: Int { libraries.reduce(0) { $0 + $1.fileLabelsAdded } }
    /// 取り込めないライブラリ。UI はこれを見て「先に有効化してください」と案内する。
    public var missingLibraries: [LibraryChange] { libraries.filter { $0.kind == .missing } }
}

/// JSON の書き出しと取り込み [IE-01〜IE-16][BK-05]。
///
/// ## 取り込みは「重ねる」だけで、消さない［設計判断］
/// 仕様 [JS-05] は 3 モード（置換／マージ既存優先／マージインポート優先）を
/// 挙げるが、この段では**インポート優先のマージ 1 本**にしている。目的が
/// 「削除したライブラリを戻せること」なので、取り込みが既存のものを消せる
/// 必要が無い——消せる取り込みは、復旧のつもりで実行して別のライブラリを
/// 失う経路になる。置換モードは 2-16 の本番で、削除の確認とあわせて設計する。
///
/// ## ライブラリの行は作らない［設計判断］
/// ライブラリを作るには Security-Scoped Bookmark が要り、**それは環境に
/// 固有なので JSON に持てない**（別のマシンでは解決できず、同じマシンでも
/// フォルダを選び直せば別のものになる）。したがって取り込みは
/// **DB に既にあるライブラリへ重ねるだけ**にし、無いものは
/// ``ImportPlan/LibraryChange/Kind/missing`` として報告する。
///
/// 削除したライブラリを戻す手順は「フォルダツリーで有効化し直す →
/// JSON を取り込む」の 2 手になるが、これは遠回りではなく**正しい手順**
/// である——実体のあるフォルダを選び直すので、外付けを繋ぎ直した・場所を
/// 移した場合にもそのまま対応できる。
///
/// ## ファイルの行も作らない
/// 取り込みが作るのは**設定・ラベルグループ・ラベル**まで。ファイルの行は
/// 再スキャンが実体から作り、そこへ評価・手動ラベル・手動タイトルを
/// 載せ直す [MG-24]。文書にあって DB に無いファイルは
/// ``ImportPlan/LibraryChange/filesMissing`` として数え、行は作らない
/// ——実体を伴わないレコードを増やすと、次の走査でそれが孤立として
/// 現れ「消えたファイル」の報告に混ざる [ID-06]。
///
/// つまり完全な復旧手順は **「有効化 → 取り込み → 再スキャン → 取り込み」**
/// ではなく **「有効化 → 再スキャン → 取り込み」** である [MG-24]。
/// UI はこの順序を案内する。
public protocol BackupRepository: Sendable {
    /// 現在の DB を文書に写す [IE-01][IE-02]。
    func export(scope: BackupScope, appVersion: String?) async throws -> BackupDocument
    /// 取り込んだ場合に何が起きるかを数える。**DB は変えない** [IE-11]。
    func plan(_ document: BackupDocument) async throws -> ImportPlan
    /// 取り込む。**単一のトランザクションで行う** [JS-08]——途中で失敗した
    /// ときに半分だけ取り込まれた状態を残さない。
    func `import`(_ document: BackupDocument) async throws -> ImportPlan
}
