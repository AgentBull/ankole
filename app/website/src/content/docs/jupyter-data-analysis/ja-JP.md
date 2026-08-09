---
title: Jupyter データ分析
description: ライブ Jupyter kernel で反復的な Python データ分析を実行する agent のセットアップ方法 — jupyter-live-kernel skill、DataFrame の検査、実践例。
section: Guides
order: 304
---

データ分析は反復的です。DataFrame を調べ、クエリを調整し、結果をプロットし、繰り返します。1 回限りの Python プロセスでは、呼び出し間で状態を保持できません。`jupyter-live-kernel` skill は、agent が複数の cell にわたって駆動するライブ Jupyter kernel を実行して状態を保持することで、これを解決します。このガイドは、データ分析 agent の実践的な形です。

最初に決定的な性質を示します。Jupyter kernel は **cell をまたいで stateful** です。変数、DataFrame、import、プロット状態は、agent の呼び出し間で永続します。これが反復分析を可能にします。agent は各ステップでデータを再ロードしたり、ライブラリを再インポートしたりしません。

## 必要なもの

- **`jupyter-live-kernel` skill が有効であること。** `default_enabled: true` です。[Skills](../skills/) を参照してください。
- **worker イメージ。** Agent Computer Worker イメージは Python、Jupyter、`hamelnb` kernel をインストールします。これらはイメージの一部です。
- **`primary` model profile がバインドされていること。** agent が Python コードを書き、kernel がそれを実行します。

## kernel を使う場合と 1 回限りの script を使う場合

次の場合に Jupyter kernel を使います。

- 作業が**反復的**である場合 — 検査、調整、再検査
- **状態を永続**させる必要がある場合 — ロードされた DataFrame、フィッティング済みの model、インポート済みのライブラリ
- agent が最終クエリを書く前にデータの形を**探索**する必要がある場合

次の場合に 1 回限りの Python プロセス（`command` 経由）を使います。

- script が**ステートレス**である場合 — 1 回実行して出力を生成して完了
- 作業が**バッチ変換**である場合 — ファイルを変換し、検査は不要

skill の `SKILL.md` はこう述べています: 「ステートレスな script には、1 回限りの Python プロセスを優先してください。」

## kernel の仕組み

`jupyter-live-kernel` skill はバックグラウンド Job（`ankole-runtime: background_job`）として実行されます。worker 内で Jupyter kernel を起動し、agent は skill のツールを通じて kernel に cell を送ります。各 cell は kernel の永続状態で実行されます。cell 1 で定義した変数は、cell 5 で利用できます。

kernel はバックグラウンド Job の間、起動したままです。Job が終了すると kernel は停止し、その状態は消えます。一時的な実行状態であり、永続的ではありません。

## 実践例

チームが channel に置いた CSV を分析する agent をセットアップします。

1. `jupyter-live-kernel` skill が有効であることを確認します（デフォルトで有効です）。
2. agent を作成し、`MISSION.md` を作成します: 「channel に CSV が現れたら、DataFrame にロードし、スキーマと要約統計を検査し、異常を特定し、プロット付きの所見を報告してください。」
3. channel で CSV をアップロードします（worker-file ルート経由、または URL を提供）。
4. agent はバックグラウンド Job に委任し、kernel を起動して CSV をロードし、反復的に検査し、プロットを生成して、結果を報告します。

## このガイドではないもの

Python や pandas のチュートリアルではありません。agent がコードを書き、skill が実行環境を提供します。notebook 作成のガイドでもありません。kernel は agent の使用のためのものであり、保存した notebook を生成するためのものではありません（タスクが求めれば、agent は保存できますが）。そして、skill の `SKILL.md` を読むことの代わりでもありません。そのファイルこそが権威あるリファレンスです。

## 次のステップ

- skill システムについては [Skills](../skills/) と [Writing a skill](../writing-a-skill/) を参照してください。
- shell ツールについては [Code execution](../code-execution/) を参照してください。
- バックグラウンド Job については [Background jobs](../background-jobs/) を参照してください。
- Agent 用にファイルをアップロードするには [File management](../file-management/) を参照してください。
