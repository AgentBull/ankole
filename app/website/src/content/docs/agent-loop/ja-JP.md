---
title: Agent ループ
description: control plane の Driver、永続化されたモデルとツールのステップ、Worker の実行境界。
section: Developer guide
order: 117
---

主 Agent loop は Elixir control plane の `Ankole.Conversations` で動作します。各会話を 1 つの `:gen_statem` Driver が進めます。質問と control plane のツールには Worker は不要です。環境ツールまたは Codex が必要になった時点で Agent の Worker を起動します。

## 1 ラウンドの永続ステップ

1. open の ActorEvent を受け入れ、PostgreSQL の会話 epoch を進めます。
2. 保存された Response チェーンから進捗を復元し、モデル要求を準備します。
3. AIGateway のプロセス内 Responses API で永続 Response を開きます。
4. 宣言された owner に従い、control plane、Worker、永続待機へツールを渡します。
5. ラウンド全体の結果、待機を満たす入力の完了、回収した receipt の削除を同じトランザクションでコミットします。
6. 境界で追加入力を注入するか、最終返信と入力完了をコミットします。

AIGateway は履歴、圧縮、記憶注入、hosted ツールを所有します。Driver は反復制限、空返信の修復、反復エラーの通知、最終返信規則を所有します。全会話がこの owner を使います。Codex は Worker 内で独自の loop を保持します。

## 復旧と副作用

新 Driver は ActorEvent と Response チェーンから進捗を復元します。control plane の副作用と receipt は同じトランザクションでコミットします。チェーンに記録済みの結果を再実行しません。Worker は Response ID と call ID で環境呼び出しを識別し、新 Driver が引き継げます。Worker プロセスを失った後、安全な呼び出しは再試行し、それ以外の不明な呼び出しは `interrupted` を返します。

通常の入力は次の境界を待ちます。停止と有効な retry は現在の作業を中断します。無効な対象付き retry は現在の実行を続けます。ツール実行後の撤回や裸の retry は記録を保持し、同じチェーンに修正を注入します。

## 失敗の上限

1 ラウンド内の再試行は AIGateway、試行間の再試行は Driver が所有します。通常の入力は 6 回目の准入で dead letter になります。計画停止はトランザクションが成功した場合に試行を 1 回返します。クラッシュは返しません。Workflow と Job はそれぞれの予算を保持します。

writer の所有権は [Actor Runtime](../actor-runtime/)、実行と保存は [Agent Computer Worker](../agent-computer-worker/)、Responses は [AIGateway](../ai-gateway/) を参照してください。
