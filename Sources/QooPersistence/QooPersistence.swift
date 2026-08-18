/// QooPersistence — 永続化層（SQLite / GRDB）。
///
/// `QooKit` にのみ依存する。`QooInfrastructure` とは相互依存しない [A-01][A-02]。
/// **`GRDB` を import してよいのはこのターゲットだけ**——CI の静的検査 B-11 が
/// 他のターゲットからの import を落とす。上位層は `QooKit` のリポジトリ
/// プロトコル越しにのみ触る。
///
/// SwiftData ではなく SQLite を選んだ根拠（実測値・測定条件）は
/// `Spikes/README.md` の「T-03 / T-04: 永続化層の性能」にある。
import QooKit

public enum QooPersistence {
    public static let moduleName = "QooPersistence"
}
