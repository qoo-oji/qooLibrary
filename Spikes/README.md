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
lzma/zstd/openssl/xml2/expat は `--without-*` で無効化しているため不要。

### まだ検証していないこと（次回以降）

- **7z の一覧・展開**: libarchive 自体は 7z に対応しているが、macOS 標準
  ツールでは 7z アーカイブを作成できず、手元にサンプルがなかったため未検証。
  zip と同一の `archive_read_*` API 経路を通るため、実装上のリスクは低いと
  見ている。7z サンプルが手に入り次第、同じ `LibarchiveSpike` で検証する。
- **RAR / UnRAR (T-13 の残り半分、T-12)**: UnRAR ソースは未取得
  （`THIRD-PARTY-NOTICES.md` 参照）。RARLAB からのソース取得、
  Objective-C++ ラッパー方式の検証、`PERMISSIVE_ONLY_BUILD` 時の
  libarchive-RAR-reader へのフォールバック、実際の `.cbr` サンプルとの
  カバレッジ比較（T-12）は別セッションで着手する。
- **App Sandbox 下での動作**: 本検証は署名なしの CLI 実行ファイルとして
  行った。完了条件にある「サンドボックス下のダミーアプリで」の検証は、
  `qooLibraryApp`（フェーズ 1、entitlement 付き Xcode ターゲット）が
  できてから、同じ `CLibarchive` 経由で再検証する。ステージング展開
  （`ExtractOptions.destination` がコンテナ内 `staging/`）や
  Security-Scoped Bookmark 越しのアクセスはこのとき合わせて確認する。
- `LibarchiveSpike` のパストラバーサル・チェックは説明目的の簡易版。
  実装（`EX-10`〜`EX-24`）では正規化・シンボリックリンク解決・展開爆弾検知
  を含む `SecureExtractor`（09章 §9.3）が本実装となる。
