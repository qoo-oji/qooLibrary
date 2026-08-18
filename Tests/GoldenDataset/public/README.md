# GoldenDataset/public

ファイル名パーサ・シリーズ抽出・巻数正規化・保護文字列・変換リネームの
正しさを担保するゴールデンテストのデータセット（`docs/Specifications/16_テスト戦略.md`
§16.2）。ここに置くファイルは **CI で実行される** [B-14][MT-24]。

実在の作品名・著者名を含むサンプルはここに置かない。`../private/`
（`.gitignore` 対象）へ。[MT-28]

## データセット形式

```jsonc
{
  "datasetName": "general-comic-b-positive",
  "visibility": "public",
  "cases": [
    {
      "id": "gcb-001",
      "input": "[著者名] タイトル 第01巻",
      "context": { "template": "一般コミック(B)" },
      "expected": {
        "matched": true,
        "fields": { "@labelgroup1": "著者名", "@title": "タイトル 第01巻" },
        "series": "タイトル",
        "volume": { "kind": "numeric", "number": 1, "raw": "第01巻" }
      }
    }
  ]
}
```

## 作り直し方

```sh
QOO_REGENERATE_GOLDEN=1 swift test --filter GoldenGenerator
```

`Tests/QooKitTests/GoldenDatasetGenerator.swift` が、組み込みテンプレート
（`Sources/QooKit/Resources/Templates/`）のフォーマットへ既知の値を差し込んで
入力を組み立て、**差し込んだ値をそのまま期待値にする**。つまりここの期待値は
実装の出力を写したスナップショットではなく、仕様から導いた答え合わせである。
実装が壊れれば落ちる [GT-03]。

現在: プリセット 8 種 × 正例 22 件 + 負例 22 件 = 352 件 [MT-23]。

## 「負例」の意味

**「どのフォーマットにも一致しない」とは限らない。** 一般コミック(B) と
成年コミック(B) は `@title` 単体をフォールバックとして持つため、空白だけの
入力を除けばほぼ何でも一致する。それらのプリセットで意味のある負例は
「**構造化されたフォーマットには当たらず、フォールバックへ落ちる**」という
主張であり、`"kind": "negative"` + `matched: true` + `formatIndex: <末尾>`
で表す。

## ここで検査できないこと

プリセットのフォーマットはいずれも予約語の周りに**明示的な空白**を持つため、
弾力的空白 [WS-01〜WS-07] とフィールド値のトリムの経路を通らない。実際、
トリムを外す変異を当てても 1 件も落ちなかった。その領域は
`Tests/QooKitTests/ElasticWhitespaceTests.swift` が直接固定している。

**変異検証の記録**（`swift test --filter GoldenDatasetTests` に対して）:

| 変異 | 検出 |
|---|---|
| フォーマットの優先順を逆にする [FF-03] | 555 件が食い違う ✓ |
| リテラル比較の正準化をやめる [MT2-05] | 28 件が食い違う ✓ |
| フィールド値のトリムをやめる [WS-05] | **検出できない**（上記の理由）|
| 自由文字列を貪欲にする [FF-13] | **検出できない**——検証器が「自由文字列の隣は必ず境界」を保証するため、貪欲/非貪欲で解が変わらない（探索順の違いに留まる）|
