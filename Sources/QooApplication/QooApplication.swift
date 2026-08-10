import QooInfrastructure
import QooKit
import QooPersistence

/// QooApplication — アプリケーション層。
///
/// `QooKit` / `QooPersistence` / `QooInfrastructure` に依存する、唯一この
/// 3 層を協調させる層 [00章 §0.3]。
///
/// 実装予定: `Command` / `CompositeCommand` / `CommandStack`（単一インスタンス
/// [UD-02]）、`LockManager`（単一インスタンス [LK-11]）、各 `*UseCase`、
/// `NotificationRouter`（11〜12章）。
public enum QooApplication {
    public static let moduleName = "QooApplication"
    public static let dependsOn = [QooKit.moduleName, QooPersistence.moduleName, QooInfrastructure.moduleName]
}
