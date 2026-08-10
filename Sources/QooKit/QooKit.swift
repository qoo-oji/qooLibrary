/// QooKit — ドメイン層。
///
/// `Foundation` 以外への依存を持たない。`SwiftData` / `AppKit` / `SwiftUI` を
/// import してはならない [A-01]（CI 静的検査 B-11 で強制する）。
///
/// 実装予定: 文字列正規化・値型（03章）、ファイル名フォーマットパーサ（04章）、
/// シリーズ抽出・巻数（05章）、リネームエンジン（06章）。
/// いずれも実ファイルには触れない純粋関数として実装する。
public enum QooKit {
    public static let moduleName = "QooKit"
}
