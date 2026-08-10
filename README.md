# qooLibrary

macOS 用のマンガ・同人誌ライブラリ管理アプリ（Swift / SwiftUI / SwiftData）。
ファイル名・フォルダ構成からラベルを自動抽出し、Finder 代替のファイル管理・
ライブラリ管理・取り込みワークフローを提供する。

> **現在の状態: フェーズ 1（ファイルマネージャー）着手中。** アプリ本体
> （`qooLibraryApp`）は起動でき、デザイントークンが配線された空の 3 ペイン
> ウインドウを表示する（1-1 完了）。フォルダツリー・ファイル一覧・ファイル
> 操作などの実機能はまだ無い。

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

### アプリ本体（qooLibraryApp）

`qooLibrary.xcodeproj` は手で編集せず、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
で `project.yml` から生成する（`.gitignore` 対象。ThirdParty の xcframework と
同じく、生成物はコミットしない）。

```sh
brew install xcodegen   # 初回のみ
Scripts/build-libarchive.sh
Scripts/build-unrar.sh
xcodegen generate
xcodebuild -project qooLibrary.xcodeproj -scheme qooLibraryApp -configuration Debug build
```

`project.yml` を変更したら `xcodegen generate` で再生成すること。App Sandbox
entitlement は `Sources/qooLibraryApp/qooLibrary.entitlements`。

### libarchive の組み込み

`ThirdParty/libarchive/` に libarchive（BSD-2-Clause）をソースからビルドして
同梱する。システムの `libarchive.dylib` にはリンクしない。

```sh
Scripts/build-libarchive.sh
```

初回ビルド前に一度実行しておくこと（ソース取得とビルドをここで行う。
生成物は `.gitignore` 対象で、リポジトリには含めない）。

### RAR / UnRAR

`ThirdParty/unrar/` に UnRAR（RARLAB 製、MIT ではない専用ライセンス。
`THIRD-PARTY-NOTICES.md` 参照）をソースからビルドして同梱する。既定ビルド
はこれを使う。

```sh
Scripts/build-unrar.sh
```

初回ビルド前に一度実行しておくこと（`Scripts/build-libarchive.sh` と同様、
生成物は `.gitignore` 対象）。

`PERMISSIVE_ONLY_BUILD=1 swift build` では UnRAR 関連ターゲットが
`Package.swift` から丸ごと除外され、`Scripts/build-unrar.sh` を実行しなくて
もビルドできる。この構成では libarchive 自身の RAR リーダーにフォール
バックする。カバレッジの差は `Spikes/README.md`（T-12）に測定結果がある。

### Gatekeeper（公証なし配布）

本アプリはソース公開のみで、署名済みバイナリの公証は行わない方針
（`docs/Specifications/17_実装ロードマップ.md` R-07）。配布物の実行手順は
フェーズ 1 完了後、ここに追記する。

## ライセンス

`Sources/` 配下は MIT（`LICENSE` 参照）。`ThirdParty/` 配下は個別ライセンス
（`THIRD-PARTY-NOTICES.md` 参照）。
