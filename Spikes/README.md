# Spikes

技術検証（T-xx, `docs/Specifications/16_テスト戦略.md` §16.6）の検証コード置き場。
本実装には組み込まず、判断根拠として残す。

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
  されたもの）での成功率はどちらも大差なく高いと推測される。0-2 として
  正式に完了させるには、ユーザー自身の実 `.cbr` サンプルでの再測定が必要。
- libarchive 側のクラッシュ耐性の弱さは、`AB-02`（扱えないアーカイブは
  理由を明示して中止）を満たすうえで無視できない。展開処理は
  `ArchiveBackendRegistry` 経由の一箇所に閉じているため、将来的に
  タイムアウト・別プロセス化などの防御を追加する変更コストは小さい。

### まだ検証していないこと（次回以降）

- **7z の一覧・展開**: libarchive 自体は 7z に対応しているが、macOS 標準
  ツールでは 7z アーカイブを作成できず、手元にサンプルがなかったため未検証。
  zip と同一の `archive_read_*` API 経路を通るため、実装上のリスクは低いと
  見ている。7z サンプルが手に入り次第、同じ `LibarchiveSpike` で検証する。
- **実 `.cbr` での T-12 再測定**: ユーザー自身の手持ちファイルが必要
  （0-2 は正式には未完了のまま）。
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
