//
//  ライブラリの世代番号 [§19.13 #2]。画面が「読み直すべきか」を判断する
//  **唯一の合図**。
//
import Foundation
import Observation

/// DB の中身が変わるたびに増える 1 つのカウンタ。
///
/// ## なぜ 1 つに畳んだか
///
/// 以前は合図が 4 系統あった——`CommandStack.operationHistory.count`（評価・
/// ラベル・タイトルの編集）、`LibraryServices.contentRevision`（走査・保管庫）、
/// `library.settingsRevision`（設定保存）、`NotificationRouter.historyRevision`
/// （通知）。「DB を触る導線を画面へ足したら `.task(id:)` の鍵も足す」を画面
/// ごとに繰り返すことになり、**足し忘れが実機で 2 度出た**（設定ウインドウが
/// ⌘Z に追随しない・ラベルフィルタが走査に追随しない）。
///
/// DB を書く経路が必ずここを進め、ライブラリ関連のビューはこれだけを観る。
/// 粗くなるぶん無関係な読み直しが増えるが、読み直し自体はミリ秒単位の
/// 問い合わせで（10 万件・50 万紐づけでも 105 ms、実測）割に合う。
///
/// ## 混ぜないもの
///
/// - **`library.settingsRevision`**（DB 列）はパーサのキャッシュ鍵 [VT-02] で、
///   画面の合図ではない。設定を保存したときは**両方**進める。
/// - **`NotificationRouter.historyRevision`** は通知履歴ウインドウ専用
///   ［ユーザー判断］。混ぜると、走査のたびに通知履歴が・通知のたびに
///   ライブラリのビューが読み直される。
///
/// ## 以前の合図が抱えていた欠陥
///
/// `operationHistory.count` は上限 500 件で頭打ちになる。**501 回目以降の操作
/// では値が動かず**、それを鍵にしていた画面は ⌘Z に追随しなくなっていた
/// ——長いセッションでだけ、しかも黙って起きる形。単調増加のカウンタに
/// 変えたことでこの穴も塞がった。
@MainActor
@Observable
public final class LibraryGeneration {
    public static let shared = LibraryGeneration()

    /// 値そのものに意味は無い。**変わったこと**だけが合図である。
    public private(set) var value = 0

    public init() {}

    /// DB の中身を変えた経路が呼ぶ。`&+` で包む——単調増加であればよく、
    /// 桁あふれで巻き戻っても「変わった」ことは伝わる。
    public func bump() { value &+= 1 }
}
