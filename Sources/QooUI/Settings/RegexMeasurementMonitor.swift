//
//  正規表現の実測 [SE-25 の層 ③、05章 §5.6]。
//
//  `LibrarySettingsDraft.measuredIssues(samples:)` は**実際に正規表現を走らせて
//  時間を測る**ので、`validate()`（描画のたびに何度も呼ばれる）に混ぜてはならない
//  ——危険な正規表現を直している最中にこそ画面が重くなる。かといって呼ばなければ
//  層 ③ そのものが無い。**草案が落ち着いたら 1 度だけ測る**のがこの型の仕事。
//
//  **設定を編集する画面は 3 つある**（設定ウインドウ・登録ウィザード・
//  テンプレート管理）。3 つが別々に測ると、片方だけ直して取り残す——このコード
//  ベースが繰り返し踏んでいる形なので、仕組みはここ 1 つに集める。
//
import Foundation
import Observation
import QooKit

/// 草案が落ち着いたら実測し、その結果を持つ。
///
/// **`validate()` の結果は持たない。** あちらは計算プロパティとして常に最新で、
/// ここが持つのは「測らないと分からないぶん」だけ——2 つを足したものが
/// 画面に出る不備の全部になる。
@MainActor
@Observable
public final class RegexMeasurementMonitor {

    /// 直近の実測で見つかった警告。**まだ測っていない間は空。**
    public private(set) var issues: [LibrarySettingsIssue] = []

    /// `issues` がどの入力に対する結果か。合わなくなったら捨てる。
    private var measuredKey: RegexMeasurementKey?
    private var pending: Task<Void, Never>?

    /// 草案が落ち着いたと見なすまでの待ち時間。
    ///
    /// 実測そのものは**映像プリセット（巻数 12 本・保護文字列 3 本）で 17 ms、
    /// 危険なパターンを 1 本足して 38 ms**［実測 2026-09-08］——1 度なら安いが、
    /// 打鍵のたびに走らせると `validate()` に混ぜたのと変わらなくなる。
    private let delay: Duration

    /// テストから測定そのものを差し替えるための口。既定は本物。
    private let measure: @Sendable (LibrarySettingsDraft, [String]) -> [LibrarySettingsIssue]

    public init(
        delay: Duration = .milliseconds(400),
        measure: @escaping @Sendable (LibrarySettingsDraft, [String]) -> [LibrarySettingsIssue]
            = { $0.measuredIssues(samples: $1) }
    ) {
        self.delay = delay
        self.measure = measure
    }

    // **`deinit` で `pending` を止めない。** Swift 6 では非分離の `deinit` から
    // メインアクタ隔離のプロパティに触れられない（`WindowFrameAutosave` で
    // 踏んだのと同じ）。待っているタスクは `weak self` しか持たないので、
    // 放っておいても待ち時間ぶんで静かに終わる。

    /// 草案が変わるたびに呼ぶ。**同じ入力なら何もしない。**
    ///
    /// - Parameters:
    ///   - draft: いまの草案。`nil`（ライブラリ未選択・読み込み前）なら結果を捨てる。
    ///   - samples: そのライブラリの実ファイル名。敵対的な合成標本に加わる。
    public func update(for draft: LibrarySettingsDraft?, samples: [String] = []) {
        guard let draft else {
            pending?.cancel()
            pending = nil
            measuredKey = nil
            issues = []
            return
        }
        let key = draft.regexMeasurementKey
        // **綴りが変わっていないなら測り直さない。** 草案は 1 打鍵ごとに
        // 書き換わるので、ここで絞らないとフィールド名を打っているだけで
        // 警告が消えたり出たりする。
        guard key != measuredKey else { return }

        // 前の結果は**別のパターンについての警告**なので、そのまま出し続けない。
        pending?.cancel()
        measuredKey = nil
        issues = []

        pending = Task { [weak self, delay, measure] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // **メインアクタの外で測る。** 38 ms はフレームを落とす。
            let found = await Task.detached(priority: .utility) {
                measure(draft, samples)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.measuredKey = key
            self.issues = found
        }
    }

    /// 画面に出す不備 ＝ **静的検査（常に最新）＋ 実測（落ち着いてから）**
    /// [SE-25 の層 ②③]。
    ///
    /// **順序は静的検査が先。** 実測は遅れて増えるので、後ろへ足すほうが
    /// 一覧の行が動かない——直そうとしてクリックする先が変わらない。
    ///
    /// 併合を呼び出し側に書かせないのは、**設定を編集する画面が 3 つある**
    /// ため（設定ウインドウ・登録ウィザード・テンプレート管理）。3 箇所に
    /// 同じ式を書くと、片方だけ直して取り残す。
    public func merged(with statics: [LibrarySettingsIssue]) -> [LibrarySettingsIssue] {
        statics + issues
    }

    /// 測り終わるまで待つ（テストと、明示的に測り切りたい経路のため）。
    public func waitForMeasurement() async {
        await pending?.value
    }
}
