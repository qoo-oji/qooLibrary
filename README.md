# qooLibrary

macOS 用のマンガ・同人誌ライブラリ管理アプリ（Swift / SwiftUI / SwiftData）。
ファイル名・フォルダ構成からラベルを自動抽出し、Finder 代替のファイル管理・
ライブラリ管理・取り込みワークフローを提供する。

> **現在の状態: フェーズ 0（基盤検証）着手中。** アプリ本体（SwiftUI 実行可能形態）
> はまだ存在しない。現時点で存在するのは、実装の土台となる SwiftPM パッケージ
> （`QooKit` / `QooPersistence` / `QooInfrastructure` / `QooApplication`）と、
> アーカイブライブラリ（libarchive）の組み込み検証のみ。

## 設計仕様書

実装の一次資料は [`docs/Specifications/`](docs/Specifications/) にある。
全体像は [`00_概要とドキュメント構成.md`](docs/Specifications/00_概要とドキュメント構成.md)
を参照。リポジトリ運用ルールは [`CLAUDE.md`](CLAUDE.md) にまとめている。

## ビルド

Xcode 26 以降（Swift 6 言語モード、`swiftLanguageModes: [.v6]`）が必要。

```sh
swift build
swift test
```

`Package.swift` は `QooKit`（ドメイン層、Foundation のみに依存）、
`QooPersistence`（SwiftData）、`QooInfrastructure`（ファイル操作・アーカイブ・
監視）、`QooApplication`（ユースケース・Undo・排他制御）の 4 ライブラリ
ターゲットで構成される。依存方向は一方向（`QooApplication` →
`QooPersistence`/`QooInfrastructure` → `QooKit`）に固定されており、CI の
静的検査で強制している（`Scripts/` 参照）。

SwiftUI アプリ本体（`qooLibraryApp` / `qooLibrary.xcodeproj`、App Sandbox・
entitlement を含む）はフェーズ 1 で追加する。

### libarchive の組み込み

`ThirdParty/libarchive/` に libarchive（BSD-2-Clause）をソースからビルドして
同梱する。システムの `libarchive.dylib` にはリンクしない。

```sh
Scripts/build-libarchive.sh
```

初回ビルド前に一度実行しておくこと（ソース取得とビルドをここで行う。
生成物は `.gitignore` 対象で、リポジトリには含めない）。

### RAR / UnRAR

現時点では未組み込み（フェーズ 0 の技術検証項目として別途着手予定）。
組み込み後は既定ビルドで UnRAR を使用し、`PERMISSIVE_ONLY_BUILD`
構成では UnRAR を除外して libarchive の RAR リーダーにフォールバックする
（機能差については `THIRD-PARTY-NOTICES.md` を参照）。

### Gatekeeper（公証なし配布）

本アプリはソース公開のみで、署名済みバイナリの公証は行わない方針
（`docs/Specifications/17_実装ロードマップ.md` R-07）。配布物の実行手順は
フェーズ 1 完了後、ここに追記する。

## ライセンス

`Sources/` 配下は MIT（`LICENSE` 参照）。`ThirdParty/` 配下は個別ライセンス
（`THIRD-PARTY-NOTICES.md` 参照）。
