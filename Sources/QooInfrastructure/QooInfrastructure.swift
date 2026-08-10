import QooKit

/// QooInfrastructure — インフラ層。
///
/// `QooKit` にのみ依存する。`QooPersistence` とは相互依存しない
/// [A-01][A-02]。
///
/// 実装予定: `FileOperationService`（ファイルシステム変更はこの層に集約する
/// [FO-01][FO-02]、CI 静的検査 B-10 で強制）、`ExpectedChangeLedger`、
/// `ArchiveBackendRegistry`（libarchive / UnRAR、08〜09章）、
/// `FSEventsWatcher` / `VolumeMonitor` / `ScanEngine`（10章）。
public enum QooInfrastructure {
    public static let moduleName = "QooInfrastructure"
    public static let dependsOn = QooKit.moduleName
}
