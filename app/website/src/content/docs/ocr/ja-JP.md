---
title: OCR テキスト認識
description: GPU も外部の OCR サービスも使わずに、Agent にスキャンした PDF、写真、スクリーンショット、領収書を読ませる方法。
section: User guide
order: 25
---

ファイルを Agent に送り、必要なテキストを伝えるだけです。Ankole には Agent Computer Worker に OCR が組み込まれているため、model の Provider や API key、独立した OCR サービスを設定する必要はありません。

たとえば、次のように依頼できます。

```text
Read all text in this screenshot and keep the original reading order.

Extract pages 2 to 5 from this scanned PDF. Mark any text that you cannot read with confidence.

Read this receipt and list the merchant, date, items, tax, and total.
```

## 一般的な CPU で動く高度な認識

Ankole は、最先端で CPU に対応した [PaddleOCR PP-OCRv6 medium](https://www.paddleocr.ai/latest/en/version3.x/algorithm/PP-OCRv6/PP-OCRv6.html) の検出・認識モデルを使います。medium は PP-OCRv6 ファミリーの中で精度を重視したモデルです。PaddleOCR の評価では、PP-OCRv5_server と比べて text detection が 4.6% 向上し、text recognition が 5.1% 向上しています。

1 つのモデルで 50 言語に対応します。簡体中国語、繁体中国語、英語、日本語、46 のラテン文字系言語が含まれます。文書のスキャンに加え、スクリーンショット、看板、商品ラベル、デジタルディスプレイなどの実際の場面のテキストも処理できます。

Ankole は OpenVINO で最適化した CPU 推論パスを使って、モデルをローカルで実行します。通常の Worker でも GPU なしで高速なローカル認識が可能です。モデルは Worker イメージにすでに含まれているため、文書が外部の OCR サービスに送られることはなく、ページごとの費用も発生しません。

## Ankole が精度の高い手順を選ぶ

OCR はピクセルからテキストを推定しますが、通常の抽出は元の文字を読み取ります。Ankole は、その手順が利用可能なときはより精度の高い方を選びます。

- テキストレイヤーがある PDF では、Agent が元のテキストを抽出します。
- 全面スキャンの PDF では、全ページを認識します。
- 混在 PDF では、OCR が必要なページにだけ使い、他のページは直接抽出します。
- DOCX、PPTX、XLSX ファイルでは、Agent は各ページを画像として扱うのではなく、文書構造を読みます。

この手順を自分で選ぶ必要はありません。可能なら元のファイルを送り、得たい結果を伝えてください。

## Agent が返せるもの

Agent は、認識されたテキストから plain text、整形された transcript、要約、または構造化された事実を返せます。OCR は各行の位置と confidence も提供します。これにより Agent は読み順を保ち、スキャンの品質が不十分で信頼できない場合に警告できます。

よい結果を得るには、鮮明で、正しい向きで、十分な解像度の画像を使ってください。元に小さな文字がある場合は、圧縮したスクリーンショットではなく元のファイルを送ってください。また、Agent に確定できない行を黙って推測させず、報告するよう依頼できます。

## 制限

- 韓国語、アラビア語、キリル文字、タイ語など、50 言語モデルの対象外の文字体系には対応していません。
- 手書き文字、数式、複雑な表、曲線状のテキスト、ぼやけたり大きく傾いた写真は、精度が落ちることがあります。表は位置付きのテキスト行として返されますが、表構造の保持は保証されません。
- OCR は内容を読み取りますが、元の PDF に検索可能なテキストレイヤーを追加するわけではありません。

`ocr` Skill は既定で有効です。Agent が OCR を利用できないと言う場合は、Agent が最新の Worker イメージを使っていることと、**Agent Library** で Skill が有効になっていることを確認してください。
