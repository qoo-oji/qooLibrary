# CLAUDE.md

qooLibrary の実装作業でこのリポジトリを扱う際に、Claude Code が常に踏まえておくべき情報をまとめる。

## 0. 現在の状態

**フェーズ 0（基盤検証）着手済み。** `docs/Specifications/17_実装ロードマップ.md` §17.2 の 0-1（libarchive の組み込み検証・zip 半分）と 0-4（プロジェクト骨格）が完了している。

- `Package.swift`（`QooKit`/`QooPersistence`/`QooInfrastructure`/`QooApplication` + `CLibarchive` + `QooKitTests`）が存在し、`swift build` / `swift test` がグリーン。
- `Scripts/build-libarchive.sh` で libarchive をソースからビルドし `ThirdParty/libarchive/libarchive.xcframework`（arm64+x86_64 ユニバーサル）を生成する。システムの `libarchive.dylib` にはリンクしない [LC-15][B-02]。
- `Spikes/LibarchiveSpike` で zip の一覧・展開が実際に動作することを確認済み（`Spikes/README.md` に詳細）。7z・RAR/UnRAR・App Sandbox 下での検証は未着手。
- 静的検査 `Scripts/check-fileops-isolation.swift`（B-10）・`check-layer-dependencies.swift`（B-11）・`check-json-completeness.swift`（B-13, 現状はプレースホルダ）と CI（`.github/workflows/ci.yml`）を用意した。
- **未着手**: UnRAR の組み込み（0-1 の残り半分・0-2 の RAR カバレッジ差分）、ゴールデンサンプル収集（0-3、ユーザーの実ファイル名が必要）、`qooLibraryApp`（SwiftUI アプリ本体・`qooLibrary.xcodeproj`・App Sandbox entitlement）はフェーズ 1 で着手する。
- 各 `Sources/*/*.swift` の中身はまだプレースホルダ（モジュール依存関係を検証するための最小限のマーカー型のみ）で、ドメインロジック・SwiftData モデル・UI は一切実装していない。

作業を始める際は、対象領域の仕様書（下記 §2 の一覧）を該当箇所だけ `Read` してから着手する。仕様書は合計 18 ファイルあり、全部を毎回読み込む必要はない。要件定義書本体は `docs/Requirements/qooLibrary_要件定義書_v2.8.md` にある（約 2,900 行）。矛盾したときの優先順位は §1 参照。

## 1. アプリ概要

qooLibrary は macOS 用の**マンガ・同人誌ライブラリ管理アプリ**（Swift / SwiftUI / SwiftData）。3 つの役割を段階的に提供する。

1. **ファイルマネージャー** — Finder の代替として日常使用できる
2. **ライブラリマネージャー** — ファイル名・フォルダ構成からラベルを自動抽出し、フィルタ・検索・評価・カバー画像などで管理する
3. **テンポラリフォルダ** — 取り込んだファイルを自動リネーム・変換リネーム・一括リネームで整形し、ライブラリへ投入するワークフロー

対応する要件定義書は「qooLibrary 要件定義書 v2.8」（約 1,053 要件 ID、`docs/Requirements/qooLibrary_要件定義書_v2.8.md`）。実装仕様書 `docs/Specifications/` はこれを実装に落とし込んだもので、要件 ID を `[XX-00]` の形式で併記している。両者が矛盾した場合は要件定義書が最上位だが、実務上は日常的には `docs/Specifications/` の記述に従い、矛盾を見つけたら仕様書側を直す（無断でコードだけ仕様と異なる実装にしない）。要件定義書は分量が大きいため、要件 ID の一次情報や仕様書に説明のない詳細を確認したいときだけ該当セクションを開く。

## 2. ドキュメント地図（`docs/Specifications/`）

| # | ファイル | 内容 |
|---|---|---|
| 00 | `00_概要とドキュメント構成.md` | 全体像・モジュール地図・命名規約・並行性モデル |
| 01 | `01_プロジェクト構成とビルド.md` | リポジトリ構成、SwiftPM ターゲット、entitlement、FS 適合検証 |
| 02 | `02_共通基盤_定数エラーログ.md` | `AppLimits`、`UserPresentableError`、`NotificationRouter`、ログ |
| 03 | `03_ドメイン層_正規化と値型.md` | 文字列正規化、`NormalizedString`、値オブジェクト |
| 04 | `04_ドメイン層_フォーマットパーサ.md` | ファイル名フォーマットの字句解析・構文木・マッチャ（中核） |
| 05 | `05_ドメイン層_シリーズ巻数.md` | 巻数フォーマット、シリーズ抽出、出力書式 |
| 06 | `06_ドメイン層_リネームエンジン.md` | 自動リネーム・一括リネーム・変換リネーム（純粋関数） |
| 07 | `07_永続化_スキーマとリポジトリ.md` | SwiftData モデル、`VersionedSchema`、Repository、`LabelIndex` |
| 08 | `08_インフラ_ファイル操作.md` | `FileOperationService`、期待変更台帳、衝突、ゴミ箱、アーカイブ |
| 09 | `09_インフラ_アーカイブと画像.md` | libarchive / UnRAR、文字化け対策、展開セキュリティ、サムネイル |
| 10 | `10_インフラ_監視とスキャン.md` | FSEvents、ボリューム着脱、`ScanEngine`、`IdentityResolver` |
| 11 | `11_アプリ層_コマンドとロック.md` | `Command`/`CommandStack`、`LockManager`、状態の 3 分類 |
| 12 | `12_アプリ層_ユースケース.md` | 自動ラベル付与、ライブラリ移動、重複ファイル、ウィザード等 |
| 13 | `13_UI_共通基盤.md` | デザイントークン、共通コンポーネント、エラー提示、キーバインド |
| 14 | `14_UI_メインウインドウ.md` | 3 ペイン、ツールバー、表示モード、フィルタ、検索 |
| 15 | `15_UI_専用ウインドウ.md` | 設定／ラベルグループ／保管庫／ペンディング等の専用ウインドウ |
| 16 | `16_テスト戦略.md` | ゴールデンテスト、単体・統合・性能テスト、技術検証(T-xx)計画 |
| 17 | `17_実装ロードマップ.md` | フェーズ 0〜3 の分割、DoD、依存関係 |
| 18 | `18_要件トレーサビリティ.md` | 要件 ID → 実装成果物の対照表 |

各要件は `[XX-00]` の形式で要件 ID を持つ。設計判断は `[設計判断]` と付され、選定理由が書かれている。**理由ごとコードやレビューコメントに引用してよい。**

要件定義書本体（`docs/Requirements/qooLibrary_要件定義書_v2.8.md`）はこれらの一次情報。仕様書に説明のない詳細や、要件 ID そのものの文言を確認したいときに開く。

## 3. 絶対に破ってはいけないアーキテクチャ制約

これらは CI の静的検査（`Scripts/check-fileops-isolation.swift` 等）で強制される、または後戻りが極めて困難な設計判断。実装中に「近道」で回避しない。

### 3.1 モジュール依存方向 [A-01][A-02]

```
qooLibraryApp → QooApplication → QooPersistence ─┐
                      ↓                          ├→ QooKit
                QooInfrastructure ───────────────┘
```

- `QooKit` は `Foundation` 以外に依存しない。`SwiftData` / `AppKit` / `SwiftUI` を import してはならない。パーサ・正規化・リネームエンジンはすべて**純粋関数**として実装し、実ファイルには一切触れない。
- `QooPersistence` と `QooInfrastructure` は相互依存しない。協調が必要なら `QooApplication` を経由する。
- Repository は `Sendable` な値型のみを返す。`@Model` オブジェクトや `Predicate` を API に露出させない（GRDB 等への差し替えを想定）[RP2-02][RP2-03]。

### 3.2 ファイル操作の一元化 [FO-01][FO-02]

**`QooInfrastructure/FileOps/FileOperationService` 以外から `FileManager` の変更系 API（`moveItem`/`copyItem`/`removeItem`/`createDirectory`/`trashItem`/`createFile`/`linkItem`/`replaceItem`）を呼んではならない。** これは CI で機械的に検査される最重要制約。理由: 自己変更識別（期待変更台帳）と Undo がここに集約されて初めて成立するため。

### 3.3 自己変更識別は 4 層構造 [5.4 節]

FSEvents の `IgnoreSelf` フラグだけに頼らない。① FSEvents フラグ（一次フィルタのみ）② 期待変更台帳（主たる識別手段）③ 一括操作中の監視停止 ④ リネームの冪等性検証（最終防衛線）。冪等性検証で `.diverges` と判定されたルールは**保存を拒否**する [FO-22]。

### 3.4 Command パターンと単一 Undo スタック [A-03][UD-02]

すべての変更操作は `Command` として実装し、`CommandStack.shared`（アプリ全体で単一、ウインドウ単位に分けない）を経由して実行する。`FileOperationService` が返す `OpReceipt` を Command が保持して `undo()` を実装する。

### 3.5 エラー・通知は `NotificationRouter` に一本化 [ER-01]

機能ごとに独自の提示方法（アラート・トースト等）を作らない。提示強度（1: アプリモーダル 〜 5: ログのみ）に応じた提示手段の選択は `NotificationRouter` の中だけで行う。

### 3.6 排他制御は `LockManager` 単一インスタンス [LK-11]

ファイルシステムを変更する一括処理（一括リネーム・変換リネーム・ライブラリへの一括移動・JSON インポート等）のみ排他。取得順序は UUID 昇順固定でデッドロックを防ぐ [LK-12][LK-13]。待機・キューイングはせず、取得できなければ即座に失敗する [LK-14]。

### 3.7 状態の 3 分類 [ST-20〜ST-27]

- **永続状態** → SwiftData（ライブラリ設定、ラベル、フォーマット、ペンディング等）
- **ウインドウ固有状態** → `WindowState`（ラベルフィルタ選択、表示モード、ソート順など。DB に保存しない）
- **セッション一時状態** → `SessionState`（実行中処理、ロック状態。メモリのみ）

例外: ラベルグループの表示順とピン留めはライブラリ単位の永続設定として全ウインドウ共有 [ST-23]。

### 3.8 正規化は 1 箇所にしか実装しない [3 章]

文字列の NFC 化・全角半角統一・空白畳み込みは `TextNormalizer` のみが行う。`CFStringTransform(.fullwidthHalfwidth)` は使わない（長音・半角カナを壊すため、変換表を自前で持つ）[NM-01]。

### 3.9 パーサは正規表現の連結で実装しない [FF-12]

ファイル名フォーマットは 字句解析 → 構文木 → 両端アンカー+バックトラッキング+メモ化 の 3 段構成で実装する（04 章）。

### 3.10 SwiftData は v1 から `VersionedSchema` を使う [MG-01][DP-06]

移行対象が何もなくても `SchemaV1` と空の `MigrationPlan` をファイルとして用意する。後付けはリスクが大きすぎるため。

### 3.11 再生成可能／不可能データの区別 [MG-20〜MG-23]

`@Regenerable` でマークされたデータ（サムネイル、`fileCount`、自動ラベル等）とマークされないデータ（手動ラベル、評価、手動編集タイトル等）を区別する。JSON エクスポートは再生成不可能データを漏れなく含む必要があり、CI で網羅性を検証する。

### 3.12 サンドボックス配下を汚さない [CL-01〜CL-05]

ライブラリ／テンポラリフォルダ配下にアプリ由来のファイルを作らない（例外: `.qooarchive`）。xattr へのメタデータ書き込みは行わない。`FileOperationService` に xattr 書き込み API を持たせない。

### 3.13 ネットワーク通信を実装しない [SC-01][LG2-08]

ログの送信機構、外部メタデータ連携、クラウド同期のいずれも実装しない。

## 4. 命名規約 [00 章 §0.4]

| 対象 | 規約 | 例 |
|---|---|---|
| プロトコル | 能力は `-ing`/`-able`、役割は接尾辞なし | `ArchiveExtracting`, `LibraryRepository` |
| SwiftData モデル | 名詞、`@Model final class` | `ManagedFile` |
| 値型 | 名詞、`struct` | `VolumeValue`, `ParseResult` |
| ユースケース | `<動詞><対象>UseCase` | `ApplyAutoLabelsUseCase` |
| コマンド | `<動詞><対象>Command` | `MoveFilesCommand` |
| SwiftUI View | `<対象>View`/`<対象>Pane`/`<対象>Window` | `LabelFilterPane` |
| エラー | `<領域>Error` | `FormatCompileError` |
| 定数 | `AppLimits`/`AppDefaults` に集約。マジックナンバー直書き禁止 | `AppLimits.maxLabelGroups` |

- コード中のコメントに要件 ID を残す。特に制約系（`FO-01`, `MG-01`, `LK-13` 等）は該当箇所に `// [FO-01]` を付す。
- 型名・変数名は英語。コメント・ログメッセージは日本語可。ユーザー向け文字列は String Catalog（`Resources/Localizable.xcstrings`）へ。

## 5. 並行性モデル [00 章 §0.5]

Swift 6 言語モード、`StrictConcurrency` 有効。

| 領域 | コンテキスト |
|---|---|
| SwiftUI View / ViewModel、`mainContext` を触る処理 | `@MainActor` |
| スキャン・サムネイル生成・一括処理・JSON 入出力 | `@ModelActor` の専用アクター |
| `FileOperationService` / `ExpectedChangeLedger` / `LockManager` | `actor`（直列化） |
| FSEvents コールバック | 専用 `DispatchQueue` → `AsyncStream` |

コンテキストをまたぐ受け渡しは `PersistentIdentifier` のみ。`@Model` オブジェクトを `Sendable` として渡さない。

## 6. 実装の進め方

`17_実装ロードマップ.md` に従い、フェーズを飛ばさない。現時点ではフェーズ 0（基盤検証）の途中（§0 参照）。

```
フェーズ0 基盤検証        T-13/T-12 の技術検証、ゴールデンサンプル収集開始、プロジェクト骨格 ← 進行中
フェーズ1 ファイルマネージャー  Finder 代替として日常使用できる状態
フェーズ2 ライブラリマネージャー ラベル管理が実用レベル
フェーズ3 テンポラリフォルダ   取り込み〜投入のワークフロー完結
```

フェーズ 0 の残り（`17_実装ロードマップ.md` §17.2）:

| # | 作業 | 状態 |
|---|---|---|
| 0-1 | libarchive / UnRAR の組み込み検証 [T-13] | zip/7z 側（libarchive）は完了。RAR/UnRAR 側は未着手 |
| 0-2 | RAR カバレッジ差分の測定 [T-12] | 未着手（UnRAR 未組み込み、実 `.cbr` サンプルも必要） |
| 0-3 | ゴールデンサンプルの収集開始 [MT-27][DP-09] | 未着手。ユーザーの実ファイル名 500 件以上が必要 |
| 0-4 | プロジェクト骨格の作成 | 完了。`swift build`/`swift test`/CI がグリーン |

- フェーズ 1 の 4 制約（DP-01 Undo 基盤 / DP-05 FileOps 集約 / DP-07 mainContext 構成 / DP-08 通知基盤）は機能追加より先に固める。後付けは大規模改修になる。
- フェーズ 2 の最初に `VersionedSchema` を導入する。パーサ（`QooKit`）は永続化と並行実装できるため早期着手を推奨。
- 各フェーズの DoD（完了条件、17 章に記載）を満たさないまま次フェーズへ進まない。

## 7. テスト方針 [16 章]

- `QooKit`（純粋関数）はカバレッジ 80% 以上必須。特に `TextNormalizer.normalize` は 100% カバレッジ必須 [NM-04]。
- **ゴールデンテスト**（`Tests/GoldenDataset/`）がパーサ・シリーズ抽出・巻数正規化・保護文字列・変換リネームの正しさを担保する主手段。プリセット 8 種それぞれに正例・負例 20 件以上。
- 実運用で誤判定が見つかったら、**そのファイル名を必ずデータセットへ追加してから修正する** [MT-25]。
- 実在の作品名・著者名を含むサンプルは `Tests/GoldenDataset/private/` に置き `.gitignore` する。CI は `public/` のみ実行。
- パーサに変更を加えたら `Tests/GoldenDataset/public` 全件を実行し、差分が出たら「期待値を直す」か「実装を直す」かを明示的に判断する。

## 8. CI 静的検査（実装後に必ず通す）

| 検査 | 内容 |
|---|---|
| FileOps 隔離 [FO-02] | `FileOps/` 以外での `FileManager` 変更系 API 呼び出しを検出したらビルド失敗 |
| 層の依存 [A-01] | `QooKit` 配下の `import SwiftData`/`AppKit`/`SwiftUI` を検出したら失敗 |
| 定数の集約 [MT-03] | マジックナンバー直書きの検出 |
| JSON 網羅性 [MG-23] | `@Regenerable` 未付与の非再生成属性が JSON DTO に存在するか検証 |
| ゴールデンテスト [MT-24] | `Tests/GoldenDataset/public` 全件 |

## 9. やってはいけないこと（明示的な禁止事項）

- `FileOperationService` を経由しないファイルシステム変更（§3.2）
- `QooKit` からの `SwiftData`/`AppKit`/`SwiftUI` の import
- ファイル名パーサを正規表現の連結で実装すること [FF-12]
- `CFStringTransform(.fullwidthHalfwidth)` による全角半角変換 [NM-01]
- xattr へのメタデータ書き込み、サイドカーファイルを作る API [CL-03][FS2-03]
- ライブラリ／テンポラリフォルダ配下への `.qooarchive` 以外のアプリ由来ファイル作成
- ログ・使用状況等のネットワーク送信機構
- 排他処理でのブロッキング待機・暗黙のキューイング（即座に失敗させる）[LK-14]
- 機能ごとに独自のエラー表示・通知 UI を作ること
- ウインドウ固有状態（表示モード、ソート順、フィルタ選択）の DB 保存
- 冪等性検証で `.diverges` と判定された自動リネームルールの保存許可
- `RarBackendName` を無視した UnRAR 由来コードの流用（「RAR 互換アーカイバの開発に使用してはならない」旨を必ず先頭コメントに記す）[LC-26]

## 10. 依存ライブラリとライセンス [01 章 §1.7]

- 自作コード（`Sources/`）は MIT。
- **libarchive（BSD-2-Clause）は組み込み済み。** `Scripts/build-libarchive.sh` がソースからビルドし `ThirdParty/libarchive/libarchive.xcframework`（gitignore 対象、要再生成）を生成する。システムの `libarchive.dylib` にはリンクしない [LC-15][B-02]。ビルド前に一度このスクリプトを実行する必要がある（README 参照）。
- **UnRAR は未組み込み。** 組み込み時は改変せず `ThirdParty/unrar/` に隔離し、ライセンス全文を同梱する。呼び出しは Objective-C++ ラッパー（`QooUnrarBridge.mm`）に閉じ込め、先頭コメントに「RAR 互換アーカイバの開発に使用してはならない」旨を記す [LC-26][B-03][B-04]。
- 依存追加時は `THIRD-PARTY-NOTICES.md` の更新を必須とする（CI の `license` ジョブが `ThirdParty/` の変更を検出して強制する）。
- `PERMISSIVE_ONLY_BUILD` ビルド構成（`PERMISSIVE_ONLY_BUILD=1 swift build`）は UnRAR 組み込み後、これを除外して libarchive の RAR リーダーを使う構成になる。既定ビルドと機能差があることをアバウト画面で明示する [B-01]。
