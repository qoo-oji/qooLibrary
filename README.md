# qooLibrary

macOS 用のマンガ・同人誌ライブラリ管理アプリ（Swift / SwiftUI / SwiftData）。
ファイル名・フォルダ構成からラベルを自動抽出し、Finder 代替のファイル管理・
ライブラリ管理・取り込みワークフローを提供する。

> **現在の状態: フェーズ 1（ファイルマネージャー）完了（v0.10）。Finder 代替
> として日常使用できる。** 次はフェーズ 2（ライブラリマネージャー）で、
> SwiftData の導入・ファイル名パーサ・ラベル管理に着手する。

実装済みの主な機能:

- **ウインドウ** — 3 ペイン（フォルダツリー／一覧／インスペクタ）、
  ネイティブタブ、複数ウインドウ、ペイン幅とウインドウ位置の記憶
- **フォルダツリー** — ボリューム／テンポラリ／ライブラリの 3 グループ、
  登録フォルダの管理、縮退状態の区別（未接続・ゴミ箱・消失）、取り出し
- **ファイル操作** — 移動・コピー・名前変更・複製・エイリアス・ロック・
  ゴミ箱・完全削除・衝突処理（置き換え／両方とも残す／スキップ）、
  ドラッグ＆ドロップ、バイト単位の進捗と一時停止・中断、Undo/Redo
- **アーカイブ** — zip / 7z / RAR / tar.gz の展開と zip / 7z の圧縮、
  文字化け対策（UTF-8 / CP932 判定）、展開爆弾・パストラバーサル対策、
  パスワード保護
- **表示** — リスト／アイコン表示、サムネイル（画像・動画・PDF・EPUB・
  アーカイブ・フォルダの中身）、バックグラウンド生成、Quick Look
- **操作系** — キーボードショートカット（カスタマイズ可）、Finder 準拠の
  メニューバーとコンテキストメニュー（⌥ 代替項目込み）、現在のフォルダ内の
  再帰検索、一括リネーム、マウスのサイドボタン／トラックパッドのスワイプに
  よる戻る・進む
- **基盤** — App Sandbox（Security-Scoped Bookmark）、ネットワーク
  ボリューム対応、エラー・通知の一元化、診断ログ、環境設定、日英ローカライズ

変更履歴は [`CHANGELOG.md`](CHANGELOG.md)、詳細な進捗・設計判断の経緯は
[`CLAUDE.md`](CLAUDE.md) を参照。

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
（`docs/Specifications/17_実装ロードマップ.md` R-07）。**配布物は用意して
いない**ため、現時点では上記の手順で自分でビルドして使う。

そのため、`/Applications` へ配置した正式なアプリとしてしか検証できない項目
（Finder の「このアプリケーションで開く」への登録など）は未検証のまま残って
いる。詳細は [`CLAUDE.md`](CLAUDE.md) の該当節を参照。

## ライセンス

`Sources/` 配下は MIT（`LICENSE` 参照）。`ThirdParty/` 配下は個別ライセンス
（`THIRD-PARTY-NOTICES.md` 参照）。

## 貢献する / 引き継ぐ

**`CONTRIBUTING.md` を先に読んでください。** このプロジェクトは実在の蔵書を
扱うため、私的なデータの扱いに固有の作法があります。

## 開発時の設定（クローンごとに 1 回）

```sh
git config core.hooksPath Scripts/git-hooks
```

私的なデータがコミットへ入るのを止める pre-commit hook を有効にする
[MT-28〜MT-32]。**内容の照合は、照合する相手（あなたの蔵書、あなたの登録
フォルダ名）が手元にしか無いため CI では原理的に走らない。** CI に頼れない
以上、コミットの瞬間に機械的に止めるしかない。

**この設定をしないと保護はありません。**
