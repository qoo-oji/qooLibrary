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

現時点（フェーズ 0）ではパーサ本体（04章）が未実装のため、このデータセットは
空。プリセット 8 種それぞれに正例・負例 20 件以上を用意する作業は、パーサ
実装（フェーズ 2, 2-3）に先行して着手できる [MT-27][DP-09]。
