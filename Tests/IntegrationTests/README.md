# IntegrationTests

`Repository`、`FileOperationService`、`ScanEngine`、アーカイブ往復などの
統合テスト置き場（`docs/Specifications/16_テスト戦略.md` §16.4）。
一時ディレクトリに擬似ライブラリを構築して実行する。

フェーズ 0 の時点では対象コードがまだ存在しないため空。`QooInfrastructure` /
`QooPersistence` の実装が進むフェーズ 1〜2 で、対応する SwiftPM テスト
ターゲットとして `Package.swift` に追加する。
