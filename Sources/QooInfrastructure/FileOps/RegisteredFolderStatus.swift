import Foundation

/// 登録フォルダの縮退状態 [1-17、8章 §8.7.1]。
///
/// ## なぜ二値では足りないのか
/// 1-13 以来ここは「ブックマークを解決できたか否か」の二値だった。しかし
/// **性質のまったく異なる事象が同じ扱いに潰れる**:
///
/// - ボリューム未接続は「待てば必ず戻る」ので登録を消してはならない [SB-05]。
/// - 完全削除は「戻らない」ので、登録の整理をユーザーに促すべきである。
/// - ゴミ箱へ移動すると**解決は成功し続ける**（BM-2）ため、二値では
///   そもそも異常として現れず、消える寸前の場所へ書き込みまで通っていた。
///
/// ## 状態のあいだの移り方
/// ```
///                ┌──────────────────────────────┐
///                │            .online           │
///                └──────────────────────────────┘
///     ボリューム取り外し │  ゴミ箱へ移動 │  完全削除 │ 再フォーマット
///                ↓              ↓          ↓          ↓
///            .offline       .inTrash    .missing  .unsupportedFileSystem
///                │              │
///        接続で自動復帰   ゴミ箱から戻せば自動復帰
/// ```
/// **どの状態でも登録レコードを自動削除しない** [RG3-04][SB-05]。解除は
/// 必ずユーザーの明示的な操作で行う。
public enum RegisteredFolderStatus: Sendable, Equatable {

    /// 通常。解決できて、実在するディレクトリで、ゴミ箱の外にある。
    case online(url: URL)

    /// ボリュームが接続されていない [SB-05][VD-11]。**接続すれば自動的に戻る。**
    ///
    /// `lastKnownPath` は最後に解決できたパス。「どのボリュームを繋げばよいか」
    /// をユーザーへ示すために持つ。まだ一度も解決できていない登録（この項目が
    /// 導入される前に作られたレコードで、以後ずっとオフラインのもの）では `nil`。
    case offline(lastKnownPath: String?)

    /// ゴミ箱の中にある [BM-2]。
    ///
    /// **要件定義書にも仕様書の当初版にも無かった状態**［設計判断］。
    /// ブックマークが inode を追跡するため解決は成功し続け、二値の設計では
    /// 「正常」に見えてしまうことが実測で判明したため新設した。
    case inTrash(url: URL)

    /// 実体が見つからない（完全削除された可能性が高い）。
    ///
    /// **「削除された」と断定はしない** [ID-06 の精神]。ボリュームは繋がって
    /// いるのに解決できない、という観測結果だけを表す。
    case missing(lastKnownPath: String?)

    /// ボリュームが同一性の追跡に対応しなくなった [FS-08]。オフラインとは区別する。
    ///
    /// 登録後にボリュームを別のファイルシステムで再フォーマットした場合などに
    /// 起こる。閲覧はできるが、移動・改名のたびにラベル・評価・カバー画像との
    /// 結びつきが失われるため、書き込みは許さない。
    case unsupportedFileSystem(url: URL, fileSystemName: String?)

    /// 解決できた URL。オフライン・消失では `nil`。
    public var resolvedURL: URL? {
        switch self {
        case .online(let url), .inTrash(let url), .unsupportedFileSystem(let url, _): url
        case .offline, .missing: nil
        }
    }

    /// 最後に分かっている場所。UI の表示と、「場所を選び直す…」パネルの
    /// 開始位置に使う。
    public var lastKnownPath: String? {
        switch self {
        case .online(let url), .inTrash(let url), .unsupportedFileSystem(let url, _): url.path
        case .offline(let path), .missing(let path): path
        }
    }

    /// この登録フォルダの中へ入って（ツリーを展開して・中央ペインで開いて）
    /// よいか。
    ///
    /// **オフラインで `false` にするのが要点** [RG3-06]。ここで `true` を
    /// 返すと、行を展開しただけで未接続のボリュームを読みに行き、ネットワーク
    /// 越しなら接続タイムアウト分ブロックする。
    ///
    /// ゴミ箱の中も `false` にする［ユーザー判断］。入れなければ中で書くことも
    /// できないので、少ない変更で実効的に塞げる。中身を確かめたいときは
    /// 「Finder で表示」から辿れる。
    public var allowsNavigation: Bool {
        switch self {
        case .online, .unsupportedFileSystem: true
        case .offline, .inTrash, .missing: false
        }
    }

    /// この登録フォルダの中へ**書き込んで**よいか（新規フォルダ・ペースト等）。
    ///
    /// `.unsupportedFileSystem` は閲覧できても書き込ませない [FS-08]。
    public var allowsWriting: Bool {
        if case .online = self { return true }
        return false
    }

    /// 通常の状態か。UI が「異常を知らせる装飾を足すか」を決めるのに使う。
    public var isDegraded: Bool {
        if case .online = self { return false }
        return true
    }
}

/// 登録フォルダ 1 件の現在の状態一式。
///
/// ``status`` と ``isNested`` は**直交する**ので 1 つの enum に混ぜない
/// ——オンラインでありながら入れ子が破れている、が正常に起こり得る。
public struct RegisteredFolderState: Sendable, Equatable, Identifiable {
    public let folder: RegisteredFolder
    public let status: RegisteredFolderStatus

    /// 外部での移動によって、登録どうしの入れ子禁止 [RG-03][RG-04] が**事後に**
    /// 破れている [RG3-05]。
    ///
    /// 登録時には弾いているが、ブックマークは移動に追従する（BM-1）ため、
    /// ユーザーが Finder で片方をもう片方の中へ移せば成立してしまう。
    /// **自動解除はしない** [RG3-04]。ツリーの行に警告を出すだけに留める
    /// ［ユーザー判断: 起動のたびにダイアログが出ると邪魔になる。状態が
    /// その場に残るので後からでも気づける］。
    public let isNested: Bool

    public var id: UUID { folder.id }

    public init(folder: RegisteredFolder, status: RegisteredFolderStatus, isNested: Bool = false) {
        self.folder = folder
        self.status = status
        self.isNested = isNested
    }
}
