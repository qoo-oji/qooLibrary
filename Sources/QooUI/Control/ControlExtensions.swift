#if DEBUG
import Foundation

/// ハンドラの結果。`Result` を使わないのは、`[String: Any]` を運ぶために
/// 失敗側へ `Error` 準拠を要求されるのが釣り合わないため。
public enum ControlOutcome {
    case success([String: Any])
    case failure(String)
}

/// アプリ層（`qooLibraryApp`）が制御口へコマンドを足すための差し込み口 [MT-33]。
///
/// **なぜ差し込みにするのか。** 口の本体は `QooUI` に置いてある（そこなら
/// `swift test` から触れる）が、ライブラリの登録・走査・解除を起こす
/// `LibraryEnableAction` はその**上**の `qooLibraryApp` に居る [A-01]。
/// 口から呼ぶために下へ降ろすと、View と絡んだ層をまるごと動かすことになる。
/// 差し込みなら層の向きを 1 つも壊さずに、**UI が押すのと同じ関数**を
/// そのまま呼べる。
///
/// **口専用の経路を作らないこと** [CT-09]。ここへ登録するハンドラは、
/// ボタンやメニューが呼ぶのと同じ関数を呼ぶ——別に書くと、口では通るのに
/// 実機では通らない（またはその逆）という食い違いが静かに生まれる。
@MainActor
public enum ControlExtensions {
    /// **非同期でよい。** 登録フォルダは `actor` なので `await` が避けられない。
    /// そのぶん、組み込みのコマンドと違って**AppKit が入れ子のイベントループを
    /// 回している間は応答しない** [CT-16]——`Task` を挟む必要があるため。
    /// ここへ足すのは、そういう場面で叩かない類の操作に限ること。
    public typealias Handler = @MainActor ([String: Any]) async -> ControlOutcome

    private static var handlers: [String: Handler] = [:]

    public static func register(_ name: String, _ handler: @escaping Handler) {
        handlers[name] = handler
    }

    static var names: [String] { handlers.keys.sorted() }

    static func handler(for name: String) -> Handler? { handlers[name] }
}
#endif
