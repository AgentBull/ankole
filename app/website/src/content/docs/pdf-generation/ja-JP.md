---
title: PDF 生成
description: PDF ファイルの作成・検証・編集を行う Agent の構成方法（pdf Skill、使用するツールチェーン、実践例）を説明します。
section: Guides
order: 306
---

レポートや提案書など、整形済みのドキュメントを PDF として納品するケースは頻繁にあります。Ankole の `pdf` Skill は、Worker にプリインストールされている PDF ツールチェーン（Pandoc、2 種類の PDF エンジン、Poppler、QPDF）を使い、バックグラウンド Job として PDF を生成します。このガイドでは、PDF を作成・検証・編集する Agent の実践的な構成手順を説明します。

押さえておきたい重要な点は、`pdf` Skill が**モデルの組み込み機能ではなく、ファイルシステムとシェルツールを組み合わせた Skill である**ということです。`generate_pdf` のような専用 API を呼び出すのではなく、Agent は Skill の `SKILL.md` に記された手順に従い、シェルツール経由で Pandoc や PDF エンジンを実行して文書を仕上げます。

## 必要なもの

- **`pdf` Skill が有効であること。** デフォルトで有効（`default_enabled: true`）になっているため、明示的に無効化しないかぎりすべての Agent で利用できます。詳しくは [Skills](../skills/) を参照してください。
- **Worker イメージ。** Agent Computer Worker イメージには、Pandoc、2 種類の PDF エンジン（Typst と LaTeX）、Poppler、QPDF があらかじめ組み込まれています。追加のインストール作業は不要です。
- **`primary` モデルプロファイルがバインドされていること。** Agent が原稿（Markdown や文書構造）を作成し、Skill のツールチェーンがそれを PDF へレンダリングします。

## skill が行うこと

`pdf` Skill の `SKILL.md` では、次の 3 つの操作が定義されています。

- **作成（Create）：** 原稿（通常は Markdown）を作成し、Pandoc と PDF エンジンを使って PDF にレンダリングします。エンジンの使い分け、フォント設定、出力先パスの扱いは Skill 側にまとめられています。
- **検査（Check）：** 生成した PDF を Poppler と QPDF で検査し、ページ数、テキスト抽出の可否、フォントの埋め込み状態を確認します。納品前に破損や文字化けがないかを確かめるために使います。
- **編集（Edit）：** 文書全体を一から再生成することなく、既存 PDF 内のテキストを部分的に修正します。

この Skill はバックグラウンド Job（`ankole-runtime: background_job`）として実行されるため、時間のかかる PDF レンダリング中でも通常の会話がブロックされることはありません。

## 完全な例

毎週のステータスレポートを PDF で自動作成する Agent を構成する手順は次のとおりです。

1. `pdf` Skill が有効になっていることを確認します（デフォルトで有効です）。
2. Agent を作成し、`MISSION.md` に次のように記述します。「毎週のステータスレポートを PDF として作成する。チャネルの履歴から今週の指標を集計して Markdown でレポートを執筆し、Typst で PDF にレンダリングしたうえで、Poppler で検証してからチャネルへ投稿する。」
3. 毎週定期実行する [schedule](../schedules/) を追加します。
4. スケジュールが発火するたびに、Agent はコンテキストを収集して Markdown 原稿を書き、シェル経由で `pdf` Skill のツールチェーンを実行し、出力結果を検証してから PDF ファイルを投稿します。

## `design-md` との併用

ブランドのカラーパレットや固有のレイアウトなど、PDF の視覚的な仕上がりにこだわりたい場合は、`pdf` Skill と `design-md` Skill を併用します。`pdf` Skill の `SKILL.md` でも、「ユーザーからすでにブランドパレットやテンプレートが指定されている場合はそれを最優先し、指定がない場合は `design-md` Skill を使ってデザイン基準を定めること」と案内されています。

## このガイドが扱わないこと

このページは Pandoc や Typst 自体の使い方を解説するチュートリアルではありません。各ツールの具体的な呼び出し手順は Skill 側に定義されており、オペレーターの役割はタスクの目的と範囲を明確に定めることです。また、レイアウトデザインの入門ガイドでもありません。視覚的な設計判断には `design-md` Skill を活用してください。なお、各ツールコマンドの正確なリファレンスについては、必ず `pdf` Skill 本体の `SKILL.md` を参照してください。

## 次のステップ

- Skill システムの全体像については、[Skills](../skills/) および [Writing a skill](../writing-a-skill/) を参照してください。
- Skill が利用するシェルツールについては、[Code execution](../code-execution/) を参照してください。
- バックグラウンド Job の仕組みについては、[Background jobs](../background-jobs/) を参照してください。
- 定期実行の設定については、[Schedules](../schedules/) を参照してください。
