/// QooPersistence — 永続化層（SwiftData）。
///
/// `QooKit` にのみ依存する。`QooInfrastructure` とは相互依存しない
/// [A-01][A-02]。
///
/// 実装予定: `VersionedSchema` / `SchemaMigrationPlan`（v1 から導入）、
/// `@Model` 定義、各 `*Repository` プロトコルとその SwiftData 実装、
/// `LabelIndex`（07章）。フェーズ 2 の 2-1 で着手する。
import QooKit

public enum QooPersistence {
    public static let moduleName = "QooPersistence"
    public static let dependsOn = QooKit.moduleName
}
