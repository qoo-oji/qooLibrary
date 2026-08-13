import os

/// OSLog カテゴリの集約 [2.6 節、MT-05]。マジックな subsystem 文字列・
/// category 名の重複を避けるため、この一箇所だけに定義する。
public enum Log {
    private static let subsystem = "com.qoolibrary.app"

    public static let fileOps = Logger(subsystem: subsystem, category: "FileOps")
    public static let scan = Logger(subsystem: subsystem, category: "Scan")
    public static let watch = Logger(subsystem: subsystem, category: "Watch")
    public static let parser = Logger(subsystem: subsystem, category: "Parser")
    public static let archive = Logger(subsystem: subsystem, category: "Archive")
    public static let db = Logger(subsystem: subsystem, category: "Persistence")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let command = Logger(subsystem: subsystem, category: "Command")
}
