---
title: Agent ループ
description: control plane の Driver、永続化されたモデルとツールのステップ、Worker の実行境界。
section: Developer guide
order: 117
---

メインの Agent ループは、Elixir control plane の `Ankole.Sessions` 内で動作し、実行セッションごとに 1 つの `:gen_statem` Driver が処理を進めます。通常の質疑応答や control plane 側で完結するツールには Worker は不要であり、環境ツールや Codex が必要になった時点で初めて Agent の Worker が起動されます。

## 1 ラウンドの永続ステップ

Driver は 1 ラウンドごとに次の永続ステップを順に進めます。

1. `open` 状態の Signal を受け入れ、PostgreSQL 上の実行セッションの epoch を進めます。
2. 保存済みの Response チェーンからここまでの進行状態を復元し、モデルへのリクエストを組み立てます。
3. AIGateway のプロセス内 Responses API を呼び出し、永続 Response を開始します。
4. ツールごとに宣言された実行主体（owner）に従い、control plane、Worker、または永続待機（durable wait）へ処理を振り分けます。
5. ラウンド全体の実行結果、待機条件を満たした入力の完了処理、および不要になった receipt の削除を同一トランザクションでコミットします。
6. ラウンド境界で追加入力があればチェーンへ注入し、なければ最終返信と入力完了をコミットします。

履歴管理、コンテキスト圧縮、記憶の注入、hosted ツールの実行は AIGateway が担当します。一方、反復回数の上限管理、空応答のリカバリ、連続エラー時の通知、最終返信の確定ルールは Driver が担当します。control plane 上で動くすべてのモデルループがこの役割分担に従いますが、Codex だけは Worker 内部に独自のループを持っています。

## 復旧と副作用

Driver が再起動または交代した場合は、Signal と Response チェーンの記録から進行状態を復元します。control plane 側の副作用と receipt は同一トランザクションでコミットされるため、すでにチェーンへ記録された処理結果が二重に再実行されることはありません。また、Worker 側の環境ツール呼び出しは Response ID と call ID で一意に識別されており、新しい Driver からそのまま引き継ぐことができます。もし Worker プロセス自体が失われた場合は、再実行しても安全な呼び出しだけをリトライし、結果が確定しない呼び出しには `interrupted` を返します。

実行中に届いた通常の追加入力は、次のラウンド境界まで待機します。一方、停止操作や有効な retry が届いた場合は、実行中の作業を即座に中断します。対象指定が無効な retry の場合は、現在の実行をそのまま継続します。また、ツール実行後のメッセージ撤回や対象指定なしの retry では、既存の実行記録を保持したまま同じチェーンに修正内容を注入します。

## 失敗の上限

1 ラウンド内のリトライは AIGateway が管理し、試行（attempt）をまたぐリトライは Driver が管理します。通常の入力は、6 回目の受け入れ（admission）に達した時点で dead letter となります。計画停止時には、停止処理のトランザクションが正常にコミットされれば試行回数が 1 回分戻されますが、クラッシュ時には戻されません。なお、Workflow と Background Agent Job はそれぞれ独立した試行回数バジェットを持っています。

writer の所有権については [Sessions](../sessions/)、ツールの実行環境とストレージについては [Agent Computer Worker](../agent-computer-worker/)、Responses の仕組みについては [AIGateway](../ai-gateway/) を参照してください。
