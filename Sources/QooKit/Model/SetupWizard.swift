//
//  初回セットアップウィザードの進行 [OB-01〜OB-10、15章 §15.12]。
//
//  **このウィザードが自前で持つのは 3 ステップだけ** [SW-02]。要件 15.12 節が
//  定める 7 ステップのうち、ステップ 4 以降は**登録ウィザードへ引き渡す**
//  [RG3-28]——テンプレートの推奨・分解プレビュー・走査の進捗・未整理の救済を
//  もう一度実装すると、いずれ片方だけが直される。対応表は 15章 §15.12。
//
import Foundation

/// このウィザードが自前で持つステップ。
///
/// **v2.16 で `fullDiskAccess` を `accessGrant` へ改称した**——フルディスク
/// アクセス（TCC）と App Sandbox は別々の強制レイヤで、前者を付与しても
/// 後者のカーネルレベルの制限は回避されないことを実測で確認したため
/// [SB-03 改訂、01章 B-20]。
public enum SetupStep: Int, CaseIterable, Sendable, Identifiable {
    /// アプリ全体の役割を 1 画面で [15.12 表]。
    case welcome = 1
    /// ボリューム／フォルダへのアクセス許可 [SB-03][SB-04]。
    case accessGrant
    /// コミック拡張子の既定アプリ [AS-03][AS-05]。
    case appAssociations

    public var id: Int { rawValue }

    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
    public var isLast: Bool { next == nil }
    public var isFirst: Bool { previous == nil }

    /// 全体の何番目か（1 始まり）。表示用。
    public var position: Int { rawValue }
    public static var count: Int { allCases.count }
}

/// 「初回起動として扱うか」の判定 [SW-01][OB-01]。
///
/// **完了印だけでは足りない。** macOS はアプリをアンインストールしても
/// `UserDefaults`（`~/Library/Containers/…/Preferences`）を消さないため、
/// 印だけを見ると**再インストールしても二度と出ない**［文献］。逆に登録の
/// 有無だけを見ると、ファイルマネージャーとしてしか使わない利用者や、
/// 意図的にすべて解除した利用者に毎起動出てしまう。
///
/// 両方を見れば「印が残っていても登録が消えていれば出る」「一度完了した人が
/// 自分で解除したのなら出ない」が同時に成り立つ。
public enum SetupWizardGate {

    public static func shouldPresent(hasCompleted: Bool, libraryCount: Int) -> Bool {
        !hasCompleted && libraryCount == 0
    }
}

/// ステップ 3「アプリの関連付け」で何を既定として選ぶか [AS-03][AS-05][SW-09]。
public enum SetupViewerChoice {

    /// 姉妹アプリ qooViewer の bundle ID [AS-05]。実機で確認した値。
    ///
    /// **見つからなければ何もしない**（システムの既定のまま）ので、将来この
    /// 値が変わっても害は「推奨されなくなる」だけに留まる。ここで固定するの
    /// ではなく「既定として選んだ状態で出す」だけで、利用者はポップアップ
    /// から変えられる [SW-09]。
    public static let qooViewerBundleID = "com.qooProject.qooViewer"

    /// ステップ 3 を開いたときに選ばれている候補。
    ///
    /// ①**既に設定済みならそれ**（「設定済み」と見せる [SW-03]）
    /// ②qooViewer があればそれ [AS-05] ③どちらでもなければシステムの既定。
    ///
    /// ①を②より先に見るのは、やり直し [OB-01] のときに利用者が自分で選んだ
    /// アプリを黙って qooViewer へ戻さないため。
    public static func resolve(candidates: [AppCandidate],
                               current: String?) -> ViewerSelection {
        if let current, candidates.contains(where: { $0.bundleID == current }) {
            return .app(current)
        }
        if candidates.contains(where: { $0.bundleID == qooViewerBundleID }) {
            return .app(qooViewerBundleID)
        }
        return .systemDefault
    }

    /// ステップ 3 の結果を実際に書き込むべきか [code-review の指摘]。
    ///
    /// **`setPrimary(nil, for:)` は「システムの既定に戻す」＝既存の関連付けを
    /// 消す書き込み**である。読み込み前（`.notLoaded`）や、利用者が何も
    /// 触っていない状態でこれを走らせると、**環境設定で設定した pdf/epub の
    /// 関連付けが黙って消える**——やり直し [OB-01] を qooViewer の無い環境で
    /// 実行すると必ず起きるうえ、初回でも「読み込みが終わる前に『完了』まで
    /// 進む」経路で起こり得る。
    public static func shouldApply(_ selection: ViewerSelection,
                                   initial: ViewerSelection) -> Bool {
        selection != .notLoaded && selection != initial
    }
}

/// ステップ 3 の選択状態。
///
/// **3 つを区別する** [code-review の指摘]。`String?` 1 つで表すと
/// 「まだ読み込んでいない」「利用者が明示的にシステムの既定を選んだ」
/// 「推奨できる候補が無い」がすべて `nil` になり、①読み込み前に確定して
/// 既存の設定を消す ②ステップ 2 へ戻って進み直すと、明示的に選んだ
/// 「システムの既定」が qooViewer へ戻る、の 2 つが起きる。
public enum ViewerSelection: Equatable, Sendable {
    /// まだ読み込んでいない。**この状態では書き込んではならない。**
    case notLoaded
    /// システムの関連付けに従う [AS2-01]。
    case systemDefault
    case app(String)

    public var bundleID: String? {
        if case .app(let id) = self { return id }
        return nil
    }
}
