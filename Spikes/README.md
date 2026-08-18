# Spikes

技術検証（T-xx, `docs/Specifications/16_テスト戦略.md` §16.6）の検証コード置き場。
本実装には組み込まず、判断根拠として残す。

0-3（ゴールデンサンプル収集）に関連する実データ調査の所見は
[`real-data-findings.md`](real-data-findings.md) を参照（実ファイル名は含まない）。

## T-13: libarchive / UnRAR の組み込み方式

### 検証したこと（zip 半分・完了）

- `Scripts/build-libarchive.sh` で libarchive 3.8.9 をソースから取得し、
  System `libarchive.dylib` にリンクせず、arm64 + x86_64 のユニバーサル静的
  ライブラリとしてビルドできる [LC-15][B-02]。
- それを `libarchive.xcframework`（`.binaryTarget`）として SwiftPM に取り込み、
  ヘッダのみの `CLibarchive` C ターゲット経由で Swift から `archive.h` /
  `archive_entry.h` の API を直接呼び出せる。
- `LibarchiveSpike` 実行ファイルで、zip アーカイブの一覧・展開が実際に動作
  することを確認した。日本語ファイル名（NFC/UTF-8）、ネストしたディレクトリ、
  0 バイトディレクトリエントリを含む。

再現手順:

```sh
Scripts/build-libarchive.sh
swift build
zip -r /tmp/test.zip <適当なフォルダ>
.build/arm64-apple-macosx/debug/LibarchiveSpike list /tmp/test.zip
.build/arm64-apple-macosx/debug/LibarchiveSpike extract /tmp/test.zip /tmp/out
```

### リンクに必要だった追加ライブラリ

libarchive は configure 時に検出したシステムの zlib / bz2 / iconv を前提にした
オブジェクトを生成する。最終リンク時に `-lz -lbz2 -liconv` が必要だった
（`Package.swift` の `CLibarchive` ターゲット `linkerSettings` 参照）。
zstd/openssl/xml2/expat は `--without-*` で無効化しているため不要。

### 教訓: 検出ベースの機能有効化はホスト環境に依存する

最初のバージョンでは `--without-lzma` を渡していなかった。開発機に liblzma の
開発ヘッダがなかったため configure が自動で xz/lzma サポートを無効化し、
ローカルではリンクが通っていた。ところが CI ランナー（GitHub Actions
`macos-latest`）には Homebrew 経由で liblzma が入っており、configure が
自動検出して xz/lzma サポートを有効化し、`-llzma` 未指定のリンクが失敗した
（`build`/`unit` ジョブで初回に検出）。

教訓として、`Scripts/build-libarchive.sh` では**使う予定のない機能はホスト環境の
検出結果に関わらず明示的に `--without-*` で無効化する**方針にした。「たまたま
このマシンにはなかったので無効化された」状態に依存しない。


### 検証したこと（RAR 半分・完了）

- UnRAR 7.2.7 のソースを RARLAB の配布元から取得し、ライセンス条項
  （`ThirdParty/unrar/license.txt`）を確認した。「RAR (WinRAR) 互換
  アーカイバの開発への使用を禁止」「配布時に本条項を含めること」の 2 点が
  中心で、要件定義書・本仕様書の前提（LC-20〜LC-27）と一致している。
- UnRAR 付属の Unix 版 `makefile` の `lib` ターゲット（`WHAT=RARDLL`）で
  `libunrar.a` を静的ビルドできた。configure 相当のスクリプトは無く、
  `CXX` に `-arch` / `-isysroot` / `-mmacosx-version-min` を渡すだけで
  arm64 / x86_64 それぞれクロスビルドでき、libarchive のときのような
  configure の空白パス問題も発生しなかった。`Scripts/build-unrar.sh` に
  同じ手順を実装し、`libunrar.xcframework` を生成する。
- **B-03 の設計判断どおり、C++ interop を直接使わず Objective-C++ の
  ラッパー 1 ファイル（`Sources/QooUnrarBridge/QooUnrarBridge.mm`）に
  UnRAR 呼び出しを閉じ込めた。** Swift からは `QooUnrarBridge.h` の素の
  C API（`qoo_unrar_list` / `qoo_unrar_extract_all`）だけが見える。
  UnRAR の `dll.hpp`（RARDLL の公開 C API）自体は `extern "C"` 済みで
  Swift から直接 import できなくはないが、仕様書の判断（ビルド安定性
  優先）に従いあえて経由しなかった。
- ラッパー内部では UnRAR の `wchar_t`（Unix では UTF-32）と Swift の
  UTF-8 `String` の変換に `NSString`（`NSUTF32LittleEndianStringEncoding`）
  を使っている。Objective-C++ だからこそ Foundation を無条件に使える、
  という設計理由（B-03 のコメント）が実際に効いた箇所。
- `UnrarSpike` で、libarchive のテストスイート由来の実 RAR ファイル
  （RAR4 / RAR5、日本語ファイル名は次項の T-12 参照）の一覧・展開が
  実際に動作することを確認した。

再現手順:

```sh
Scripts/build-unrar.sh
swift build
# 何らかの .rar ファイルを用意して
.build/arm64-apple-macosx/debug/UnrarSpike list  /path/to/sample.rar
.build/arm64-apple-macosx/debug/UnrarSpike extract /path/to/sample.rar /tmp/out
```

`PERMISSIVE_ONLY_BUILD=1 swift build` では `QooUnrarBridge` ターゲット
自体が `Package.swift` から除外され、UnRAR のソース取得すら不要になる
（`ThirdParty/unrar/` が存在しなくてもビルドできる）。

## T-12: UnRAR と libarchive の RAR カバレッジ差分

### 使ったデータ

手持ちの実 `.cbr` サンプルは無い（0-2 は本来これが前提）。代わりに
**libarchive 自身の RAR リーダーのテストスイート**
（`libarchive/test/*.rar.uu`、BSD-2-Clause、libarchive 3.8.9 に同梱、109 件）
を使った。これは実在の RAR4/RAR5 ファイル、ソリッド書庫、マルチボリューム、
暗号化書庫、および過去に見つかった不正入力・脆弱性の回帰テスト用の
（意図的に壊れた）ファイル群であり、**典型的な同人誌・マンガの `.cbr` を
代表するものではない**。あくまで実装判断の参考値として扱う。

再現: `Spikes/compare-rar-coverage.sh`（libarchive ソースを取得し、
テスト用 `.rar` を全件デコードして両バックエンドで一覧を試す）。

### 結果（一覧成功率、109 件中）

| | 成功 | 失敗 |
|---|---|---|
| UnRAR（`QooUnrarBridge`） | 81 | 28 |
| libarchive（`CLibarchive`） | 72 | 37 |
| 両方成功 | 71 | — |
| 両方失敗 | — | 27 |

- **両方失敗** の大半（暗号化ファイル名・本文暗号化の全ケースを含む）は
  パスワード付き書庫。要件どおりどちらも非対応であることが確認できた
  [AB-04][AR-08]。残りは libarchive 自身の脆弱性回帰テスト用の意図的な
  壊れ書庫（例: `block_size_is_too_small`、`decode_number_out_of_bounds_read`）
  で、どちらのバックエンドも安全側に倒して読み取りを拒否している。
- **UnRAR のみ成功**（10 件）: RAR5 マルチボリューム／ソリッドの一部、
  巨大シンボリックリンク・巨大 newsub、Unicode ファイル名など。UnRAR が
  リファレンス実装であることを考えると素直な結果。ただし
  `test_read_format_rar_invalid1.rar` は名前どおり意図的な不正入力の
  テストで、libarchive はこれを「truncated input」として正しく拒否して
  おり、UnRAR 側が「たまたま途中まで読めてしまった」だけの可能性が高い
  ＝ここでの「UnRAR 成功」を優位性として数えるのは正確ではない。
- **libarchive のみ成功**（1 件）: `test_read_format_rar5_bytes_remaining_underflow.rar`。
  UnRAR 側は `RARProcessFileW`（データ読み出し段階）で失敗した。
- **重要な発見**: `test_read_format_rar_ppmd_use_after_free.rar` /
  `…free2.rar`（過去の use-after-free 脆弱性の回帰テスト）を
  `LibarchiveSpike` に読ませると **クラッシュ（SIGTRAP）する**。エラーを
  返すのではなく異常終了するため、悪意ある `.cbr` に対する防御としては
  不十分な状態が今回のビルド構成に残っている。本実装で `SecureExtractor`
  （09章 §9.3、EX-10〜EX-24）を作る際は、少なくとも子プロセス分離か
  クラッシュ耐性のある呼び出し方を検討する必要がある
  [設計判断が必要: R-15 の対応表に追記すべき既知の懸念]。

### 実装判断への示唆

- 既定ビルドで UnRAR を優先する現在の設計（LC-11, AR-01b）は今回のデータ
  とも整合する。カバレッジで UnRAR が明確に上回っており、
  `PERMISSIVE_ONLY_BUILD` の機能差（LC-13, AR-07）も裏付けられた。
- ただし今回の母集団は「壊れた入力への耐性」テストに偏っており、実際の
  同人誌・マンガアーカイバ（多くは WinRAR / 7-Zip 等でごく標準的に圧縮
  されたもの）での成功率はどちらも大差なく高いと推測される。→ 下記の
  実データ再測定で裏付けが取れた。
- libarchive 側のクラッシュ耐性の弱さは、`AB-02`（扱えないアーカイブは
  理由を明示して中止）を満たすうえで無視できない。展開処理は
  `ArchiveBackendRegistry` 経由の一箇所に閉じているため、将来的に
  タイムアウト・別プロセス化などの防御を追加する変更コストは小さい。

### 実 `.cbr`/`.rar` での再測定（0-2 完了）

ユーザー自身の実ライブラリ（実ファイル名・内容は本リポジトリ・診断ログの
どちらにも一切記録しない。件数と一般化したエラー種別のみを記録）から、
明らかな未整理一括ダウンロード（単一ファイルが数百 MB〜数十 GB の
複数巻まとめ書庫）を除外した、個別巻相当のサイズ（300MB 未満）の実
`.rar`/`.cbr` 122 件（`.rar` 118 件、`.cbr` 4 件）で一覧を測定した。

| | 成功 | 失敗 |
|---|---|---|
| UnRAR（`QooUnrarBridge`） | 122 / 122（100%） | 0 |
| libarchive（`CLibarchive`） | 121 / 122（99.2%） | 1 |

- libarchive の唯一の失敗は `Pathname cannot be converted from UTF-16BE`。
  アーカイブ内エントリ名のエンコーディング絡みの問題で、UnRAR 側は同じ
  ファイルを問題なく読めた。日本語ファイル名を主に扱う本アプリにとって
  実質的な意味を持つ差分であり、**既定ビルドで UnRAR を優先する判断を
  実データで裏付ける結果**になった。
- 109 件の合成データ（libarchive 自身の脆弱性回帰テスト）では両者とも
  70% 台の成功率だったのに対し、実データでは両者とも 99〜100% と非常に
  高い。「壊れた入力への耐性テストは実運用の代表ではない」という上記の
  推測どおりだった。
- 300MB 以上の一括ダウンロード書庫（ユーザーの指示により対象外）は
  今回計測していない。将来これも計測するなら、複数巻を含む大きな
  ソリッド書庫としての一覧・展開性能（PF 系要件）の観点で別途見る価値が
  ある。

### まだ検証していないこと（次回以降）

- **7z の一覧・展開**: libarchive 自体は 7z に対応しているが、macOS 標準
  ツールでは 7z アーカイブを作成できず、手元にサンプルがなかったため未検証。
  zip と同一の `archive_read_*` API 経路を通るため、実装上のリスクは低いと
  見ている。7z サンプルが手に入り次第、同じ `LibarchiveSpike` で検証する。
- **App Sandbox 下での動作**: 本検証は署名なしの CLI 実行ファイルとして
  行った。完了条件にある「サンドボックス下のダミーアプリで」の検証は、
  `qooLibraryApp`（フェーズ 1、entitlement 付き Xcode ターゲット）が
  できてから、`CLibarchive` / `QooUnrarBridge` の両方について再検証する。
  ステージング展開（`ExtractOptions.destination` がコンテナ内
  `staging/`）や Security-Scoped Bookmark 越しのアクセスはこのとき
  合わせて確認する。
- `LibarchiveSpike` / `UnrarSpike` のパストラバーサル・チェックは説明目的
  の簡易版。実装（`EX-10`〜`EX-24`）では正規化・シンボリックリンク解決・
  展開爆弾検知を含む `SecureExtractor`（09章 §9.3）が本実装となる。
- 上記の libarchive クラッシュ耐性の懸念への対応方針。

## T-03 / T-04: 永続化層の性能（フェーズ2 着手前、2026-08）

`Spikes/PersistenceSpike`（本体の `Package.swift` からは独立。CI とアプリの
ビルドに影響しない）。**この測定の結果、永続化を SwiftData から GRDB へ切り替え、
`LabelIndex`（07章 §7.3 の草案）を廃止した。**

### 動機

事前調査で、SwiftData は本アプリの想定規模（`C-07`: 1 ライブラリ 5 万・全体
10 万ファイル）の境界線上にあることが分かった [文献]:

| 操作 | SwiftData | Core Data | GRDB | 生 SQLite |
|---|---|---|---|---|
| 5 万件 insert | 19.15 s | ~8 s | 0.82 s | 0.65 s |
| 20 万件 fetch | 2.1 s | 1.2 s | 0.38 s | 0.31 s |

複数の情報源が「5〜7 万レコードを超えるなら SwiftData は非推奨」で一致し、
バッチ操作・SQL 集約・全文検索を持たない点も 2026 年時点で変わっていない。
要件定義書 `R-05` はこのリスクを想定済みで、`A-02` の Repository 抽象化により
GRDB へ差し替え可能な設計を維持すると明記していた。

### 測定条件 [実測]

- macOS 26.6.2 (25G83) / Mac16,12 / 10 コア / 32 GB / Swift 6.3.3 / GRDB 7.11.1
- リリースビルド。使い捨ての一時ディレクトリ。WAL + `synchronous = NORMAL`
- **文字列は実コーパス**（`Tests/GoldenDataset/private/corpus`、2,677 件の実
  ファイル名。平均 46.6 文字 / 101 バイト）を巡回して使う。合成名で長さ分布を
  取り違えないため
- 10 万ファイル / 50 万 `fileLabel` / 10,530 ラベル（5 グループ、カーディナリティ
  3000・2000・500・30・5000 = 実データの括弧タグ平均 3.13 個に合わせた）
- 投入は 500 件バッチ [SE3-05]

### 結果

| 要件 | 目標 | 実測 | 余裕 |
|---|---|---|---|
| PF-01 起動（総件数 + ライブラリ別件数）| 2 s | **6.3 ms** | 317× |
| PF-02 フォルダ一覧（約 500 件 + ソート）| 300 ms | **10.4 ms** | 29× |
| PF-03 ラベルフィルタ 5 万件 | 500 ms | **18〜182 ms** | 2.7×（最悪ケース）|
| PF-04 部分一致検索 10 万件 | 300 ms | **20.7〜23.4 ms** | 13× |
| PF-05 初回フルスキャン 1 万件の DB 部分 | 60 s | **1.4 s** | 43× |
| PF-07 メモリ 5 万件 | 1 GB | **47 MB** | 21× |

ラベルフィルタは目的の広さを変えて測った（**狭い選択だけ測って一般化しない**）:

| 条件 | 該当 | 件数 | ソート＋先頭 200 件 |
|---|---|---|---|
| (a) 3 グループ AND（狭い）| 9 | 23.4 ms | 18.5 ms |
| (b) 低カーディナリティ 1 ラベル | 1,667 | 25.0 ms | 25.9 ms |
| (c) 1 グループ内 100 ラベルの OR | 1,700 | 23.2 ms | 23.7 ms |
| (d) 広い集合どうしの AND | 3,340 | 95.1 ms | 96.6 ms |
| (e) 全ラベル OR（ほぼ全件が該当）| 50,000 | **177.3 ms** | **182.1 ms** |
| (f) フィルタ無し 5 万件のソート＋先頭 200 件 | — | — | 12.6 ms |
| (g) 同上 + OFFSET 40000 | — | — | 43.1 ms |
| (h) ラベル + 検索 + 評価の複合 | — | — | 64.7 ms |

### この測定で確定した設計判断

| # | 判断 | 根拠 |
|---|---|---|
| 1 | **`LabelIndex`（メモリ上の索引、07章 §7.3 の草案）を作らない** | [T-03] 「グループ内 OR × グループ間 AND」は素の SQL の `INTERSECT` で表現でき、最悪 182 ms（目標 500 ms）。索引を別に持つと DB との整合性維持が新たな危険源になるだけで、得るものが無い |
| 2 | **`Label.fileCount` の非正規化カラム [DB-02] は残す。増分更新 [IX-03] も残す** | [T-04] 増分更新 0.1 ms。全件再集計 844 ms なので、破綻時の再集計コマンド [IX-04] は安価に回せる。バッジ描画のたびに集計するのは無駄なのでカラムは残す |
| 3 | **FTS5 を使わない** | `searchKey LIKE '%…%'` の全走査が 10 万件で 20.7 ms（1 件もヒットしない最悪ケース）。`PF-04` の 300 ms に対し 13 倍の余裕がある |
| 4 | **内部の行 ID は `Int64`（rowid）にする。UUID 文字列にしない** | 下表。JSON 入出力の同一性キーは UUID ではなく「相対パス + ファイル名」[JS-04] なので、外部仕様は変わらない |
| 5 | **`Codable`（`FetchableRecord`）で十分。手書き `init(row:)` は使わない** | 2 万行で 20.2 ms 対 12.1 ms。1.7 倍差だが絶対値が小さい。スキャンのホットパスだけ `db.cachedStatement` を使う |

主キーの型（10 万ファイル + 50 万 `fileLabel`、両方とも `cachedStatement` 使用）:

| 主キー | 投入 | DB サイズ | ラベルフィルタ |
|---|---|---|---|
| UUID 文字列 | 11,606 ms | 201 MB | 2.5 ms |
| **`Int64` (rowid)** | **3,848 ms** | **71 MB** | 1.9 ms |

3 倍速く、DB は 1/2.8。`fileLabel` が 50 万行あり、UUID は 36 バイト × 2 が
本体とインデックスの両方に載るため。

### GRDB の待ち先 [実測] — 1-16b の教訓の確認

8章 §8.11 で確定したとおり、**ブロッキング I/O を協調スレッドプールの上で待つと
コア数ぶん詰まった時点でアプリ全体の async 処理が止まる**。`FileIO` はそのための
逃がし先で、**逃がした先が overcommit でなければ意味が無い**（`FileIOExecutor` が
1 本の `.concurrent` queue だったときに実際に破れた [NV6-04]）。GRDB が同じ穴を
持たないかを確かめた。

`.userInitiated` で協調プールをコア数ぶん塞ぎ（**この優先度で塞がないと再現しない**
——枯渇は QoS の高いほうから低いほうへしか流れない）、対照として素の協調タスクが
1 秒経っても走り出さないことを確認したうえで測った:

| 測定 | 結果 |
|---|---|
| 枯渇中の `await pool.read` | **12 ms**（10 万件の COUNT）|
| 枯渇中の `await pool.write` | **0 ms** |
| 8 本の並行 read | 96 ms（WAL のリーダー並行性）|
| 書き込み中の read | 3 ms（書き込み全体 10 ms）|

**GRDB は協調プールの外（自前の直列 `DispatchQueue`）で待つ。**`FileIO` と同じ
性質を持つため、DB アクセスのために別の逃がし先を用意する必要はない。

### 測定手順で踏んだこと（次に測る人へ）

1. **`String(format: "%-52s", label)` は Swift の `String` に効かない。**
   数値だけが出てラベルが空欄になり、危うくそのまま読むところだった。
   CLAUDE.md に「出力が不自然なら、結論の前に書式を疑う」と記録済みの罠。
   素の padding に直した。
2. **最初の測定はラベルフィルタを「狭い選択」でしか測っておらず、該当 9 件しか
   出ていなかった。** §6.1 の「興味のあるケースだけ測って一般化した」に該当する。
   広さを変えた 5 条件へ広げたところ、最悪ケースは 10 倍（18 ms → 182 ms）だった。
3. **協調プールの枯渇プローブが空振りしていた。** 既定優先度の
   `Task.detached { sleep(3) }` では塞げず、対照（素の協調タスクの起動待ち）が
   0 ms を返して発覚した。`Scripts/thread-starvation-probe.swift` に
   「`.userInitiated` で塞ぐこと」と記録済みだったのに、それを読まずに書いた。
   **対照を入れていなければ、誤った結論をそのまま採用していた。**
4. `DatabasePool` のリーダー接続が生きている間は `PRAGMA wal_checkpoint(TRUNCATE)`
   が `database table is locked` で失敗する。サイズを測るときは `pool.close()`
   してから、`.sqlite` / `-wal` / `-shm` の合計を見る。
5. `StatementArguments([any DatabaseValueConvertible])` は**失敗しうる**
   オーバーロードに解決される。`[(any DatabaseValueConvertible)?]` として渡すと
   非失敗の初期化子に一意に決まる。

### 再現手順

```sh
swift Scripts/extract-golden-corpus.swift     # 実コーパス（任意。無ければ合成名）
cd Spikes/PersistenceSpike && swift run -c release
```

## T-05: パーサ性能（フェーズ2、2026-08）

`Tests/QooKitTests/ParserPerformanceTests.swift`（スパイクではなく恒久的な性能テスト）。

### 測定条件 [実測]

- macOS 26.6.2 / Mac16,12 / Swift 6.3.3。`swift test`（Debug ビルド）
- **実コーパス 2,677 件の実ファイル名**を巡回して 1 万件ぶんの入力を作る
- プリセット由来の 50 フォーマット。**万能フォールバックの `@title` は外す**

### 結果

| 測定 | 結果 | 目標 |
|---|---|---|
| 50 フォーマット × 1 万件 | 合計 777 ms / **0.078 ms 件** | 1 ms/件 [MT2-01] |
| 一致率 | 91.5%（8.5% は全 50 本を試して全滅）| — |
| 病的な入力（括弧を多数含む 99 文字、全滅）| **0.121 ms/件** | — |

`PF-05`（1 万ファイルのフルスキャン 60 秒）に対し、照合部分は 0.78 秒＝1.3%。

### この測定が確定させた設計判断

仕様書 04章 §4.7.1 は「前方アンカー → 後方アンカー → 中央のバックトラッキング」の
3 段構成を挙げていたが、**実装は段を分けていない**。検証器が「自由文字列フィールドの
隣は必ず境界」を保証する [FF-18][VD-02] ため、素直なメモ化バックトラッキングでも
自由文字列の走査は「次の境界を探す」だけになる、という読みが実測で裏付けられた。
段を分けるのは最適化であって正しさの要件ではないので、**測ってから足す**方針を採った。

### 測定手順で踏んだこと

**最初の測定は「50 本を走査する」測定になっていなかった。** 万能フォールバックの
`@title` がフォーマット一覧の早い位置にあり、大半のファイル名が数本目で当たって
終わっていた（一致率 **100%** で気づいた）。§6.1 の「興味のあるケースだけ測って
一般化した」に該当する。`@title` を外したところ一致率 91.5%・所要 1.2 倍になり、
初めて意図した測定になった。テストの出力に「一致率が 100% に近いなら疑え」と
書き添えてある。
