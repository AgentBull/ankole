---
title: Actor Runtime
description: 会話 Driver、永続入力と Response ログ、writer フェンス、復旧。
section: Developer guide
order: 103
---

actor key は `{agent_uid, session_id}` です。同じ Agent の会話は並行でき、1 つの会話は `Ankole.Conversations` の 1 つの Driver が順に進めます。

## 単一 writer

DynamicSupervisor は一時的な `:gen_statem` Driver を起動します。`:global` は Erlang クラスタ全体で actor key に 1 つの名前を割り当てます。永続 workspace 行の epoch が書き込みフェンスです。准入が epoch を進め、Driver は行ロックの下で確認します。ネットワーク分断後も古い Driver はコミットできません。

## プロセス消失後に残る事実

ActorEvent は永続 inbox です。AIGateway の Response チェーンはモデル出力とツール結果を記録します。control plane のツールは副作用と receipt を同じトランザクションでコミットします。Driver はラウンド全体をチェーンに移し、receipt を同じトランザクションで削除します。新 Driver はこれらの事実から進捗を復元します。

入力完了と最終返信は同時にコミットします。最後に注入された返信可能な入力が返信を所有し、内部修正は元の owner を保持します。副作用後の撤回と retry はツール記録を保持します。

## Worker の識別

環境ツールまたは Codex が必要な場合だけ Worker を要求します。環境作業の `RunRef` は Agent、Session、trigger 入力を指定します。Codex の `JobTurnRef` は Job と attempt も指定します。結果は Driver epoch ではなく操作自身の識別子で受け入れます。新 Driver は進行中の作業を引き継げます。

RuntimeFabric は Worker ごとに 1 本の Phoenix Channel を使います。Phoenix Tracker が別ノードの channel を見つけ、分散 Erlang がメッセージを届けます。現在の Worker generation と incarnation は古い route を拒否します。Worker は自身の Agent だけを処理します。

## 復旧

入力 owner は domain 書き込みと同じトランザクションで Oban wakeup を挿入します。毎分の Reconciler は開始済みの試行も含め、期限に達した全 open 入力を走査します。既存 Driver を wake するか、新 Driver を起動します。Workflow owner を通じて失われた RunServer と終端 cleanup も補います。backoff は保存済み `last_attempt_at` から計算し、失敗予算がクラッシュの反復を制限します。

単一ノードと複数ノードで同じ経路を使います。[Agent loop](../agent-loop/)、[SignalsGateway](../signals-gateway/)、[Worker](../agent-computer-worker/) も参照してください。
