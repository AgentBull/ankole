---
title: PDF 生成
description: PDF ファイルを作成・検査・編集する agent の設定方法——pdf skill、それを使うツール、完全な例。
section: Guides
order: 306
---

PDF 生成はよくある納品物です。report、proposal、あるいは PDF として届ける必要がある整形済みドキュメントなどです。Ankole の `pdf` skill は、Worker にインストールされている PDF ツールチェーン（Pandoc、2 つの PDF engine、Poppler、QPDF）を使ってこれを処理し、background job として実行されます。このガイドは、PDF を生成する agent の実際の形を説明します。

最初に決定的な性質を述べます。`pdf` skill は**ファイルシステムとツールの skill であり、model の機能ではありません**。agent は shell ツールを使って Pandoc と PDF engine を実行します。その方法は skill の `SKILL.md` に書かれています。`generate_pdf` のような API 呼び出しはありません。skill に導かれながら shell 経由で文書を準備するのです。

## 必要なもの

- **`pdf` skill が有効であること。** `default_enabled: true` なので、上書きしない限りすべての agent で有効です。[Skills](../skills/) を参照してください。
- **Worker イメージ。** Agent Computer Worker イメージには Pandoc、2 つの PDF engine（Typst と LaTeX）、Poppler、QPDF がインストールされています。これらはイメージの一部であり、自分でインストールする必要はありません。
- **`primary` model profile がバインドされていること。** agent がソースコンテンツ（Markdown または文書構造）を書き、skill のツールがそれを PDF にレンダリングします。

## skill が行うこと

`pdf` skill の `SKILL.md` は 3 つの操作を扱います。

- **作成（Create）**——ソースコンテンツ（通常は Markdown）を書き、Pandoc と PDF engine で PDF にレンダリングします。skill は engine の選択、font の設定、出力パスを把握しています。
- **検査（Check）**——Poppler と QPDF で生成した PDF を検証します（ページ数、テキスト抽出、font の埋め込み）。納品前に PDF が有効であることを確認するために使います。
- **編集（Edit）**——文書全体を再生成せずに、既存の PDF のテキストを修正します。

skill は background job（`ankole-runtime: background_job`）として実行されるため、長い PDF レンダリングは会話をブロックしません。

## 完全な例

毎週のステータスレポートを PDF で生成する agent を設定します。

1. `pdf` skill が有効になっていることを確認します（既定では有効）。
2. agent を作成し、`MISSION.md` を書きます。「毎週のステータスレポートを PDF として生成する。channel の履歴から今週の指標を集め、Markdown でレポートを書き、Typst で PDF にレンダリングし、Poppler で検証して、PDF を channel に投稿する」
3. 毎週実行する [schedule](../schedules/) を追加します。
4. 発火のたびに、agent は context を集め、Markdown を書き、shell 経由で `pdf` skill のツールを呼び出し、出力を検証してファイルを投稿します。

## `design-md` との併用

PDF に視覚的な仕上げ（brand パレット、特定のレイアウト）が必要なら、`pdf` skill を `design-md` skill と組み合わせます。`pdf` skill の `SKILL.md` にはこう書かれています。「人がすでに brand パレットやテンプレートを提供している場合は、まずそれに合わせる。そうでない場合は `design-md` skill を使い、それを設計の参照にする」

## このガイドが扱わないこと

これは Pandoc や Typst のチュートリアルではありません。ツールの呼び出し方は skill が把握しており、operator の仕事はタスクの範囲を決めることです。これはレイアウト設計のガイドでもありません。視覚的な判断は `design-md` skill を使ってください。また、`pdf` skill の `SKILL.md` を読む代わりにもなりません。ツールコマンドの正規リファレンスはそのファイルです。

## 次のステップ

- skill システムについては、[Skills](../skills/) と [Writing a skill](../writing-a-skill/) を読んでください。
- skill が使う shell ツールについては、[Code execution](../code-execution/) を読んでください。
- background job については、[Background jobs](../background-jobs/) を読んでください。
- スケジュール実行については、[Schedules](../schedules/) を読んでください。
