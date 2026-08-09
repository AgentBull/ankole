---
title: Agent ループ
description: コントロールプレーンのターンライフサイクルと worker 側の agent ループの境界 — 各側が所有するもの、通信方法、反復予算と再試行の所在。
section: Developer guide
order: 117
---

ターンは 2 つのランタイムにまたがる作業単位です。Elixir コントロールプレーンがそれをスケジュールしてフェンス管理し、Bun worker がその中の agent ループを実行します。このページは両者の境界を説明します — コントロールプレーンの `TurnLifecycle` が所有するもの、worker の `runAgentLoop` が所有するもの、そして RuntimeFabric を越えてどのように通信するか。これは [Actor Runtime](../actor-runtime/) と [Agent Computer Worker](../agent-computer-worker/) ページの上に構築されます。ここは両者の間にあるターンレベルの詳細です。

決定的な性質を先に述べます: ターンの*アイデンティティとコミット*はコントロールプレーンが所有し、ターンの*実行*は worker が所有します。ループをいつ終えるかは worker が決め、ターンの結果が永続的かどうかを決めるのはコントロールプレーンです。worker が完了と報告したターンも、コントロールプレーンがコミットするまでは永続的ではありません。

## コントロールプレーン側: TurnLifecycle

`Ankole.SignalsGateway.ActorRuntime.TurnLifecycle` はループの周りで起こることを所有し、内部は所有しません。その責務:

| 責務 | 内容 |
|---|---|
| **リース管理** | アクティベーションはリースを保持します（`activation_progress_lease_seconds` = 2100 秒、120 秒の猶予付き）。ウォッチドッグは期限切れのアクティベーションを失敗させ、そのイベントを再試行できるようにします |
| **ターン開始** | 新しいエポックで `ActorSessionActivation` を作成し、worker を割り当て、RuntimeFabric 経由でターンエンベロープを配信します |
| **ターンエラー処理** | `handle_turn_error/2` が worker のエラーレポートを受け取り、分類し、再試行かデッドレターかを決定します |
| **ターンコミット** | worker が成功を報告したとき、ターンの結果を永続的な真実として記録します |
| **アクティベーション期限切れ** | `fail_activation_if_expired/2` が、リースが切れたフリーズまたはクラッシュしたターンを検出します |

ターンエラーの再試行予算はここにあり、worker にはありません。最大 5 回の試行（`@worker_turn_error_dead_letter_attempts`）、再試行間隔は 5 秒から 120 秒の指数バックオフ（`@worker_turn_error_retry_base_seconds` と `@max`）です。失敗した試行ごとにエポックが上がるため、失敗した試行からの遅延返信は後続の再試行に一致できません。

コントロールプレーンは、モデルが何を言うか、agent がどのツールを呼ぶか、ループが何回反復するかを決定**しません**。これらは worker のものです。

## worker 側: runAgentLoop

`app/agent_computer/src/core/agent-loop.ts` の `runAgentLoop` は、worker がターン内で実行する 4 ステップのループです:

1. **モデルを呼び出す** — ターンスコープの OpenAI Responses adapter（AIGateway のステートフル転送）を通じて。
2. **関数呼び出しをローカルで実行する** — 応答に関数呼び出し項目があれば、worker がツールを実行します。
3. **出力を記録する** — AIGateway を通じて、function-call-output メッセージとして保存します。
4. **ジャーナルアンカーから続ける** — 応答がそれ以上関数呼び出し項目を返さなくなるまで。

worker は**ループの終了とローカルの反復予算**を所有します。結果は 2 つです:

- **`loop_finished`** — モデルがさらなるツール呼び出しなしで返りました。ターンは自然に終了します。
- **`iteration_exhausted`** — worker が反復上限に達しました。モデルはこれ以上のツール呼び出しではなく最終応答の合成を促され（`MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT`）、その合成でターンは終了します。

worker は 3 つの復旧プロンプトも所有します: ツール後に空応答になった場合のプロンプト（モデルがツールを実行したのに空の応答を返した）、ツールエラー復旧のヒント、反復上限の合成。これらはターンが永続的かどうかではなく、モデルが次に何をするかに関するものなので、worker 側にあります。

## worker が所有しないもの

agent-loop モジュールの doc は明示的です: worker は履歴の展開、圧縮、継続アンカー、永続的な応答状態を所有**しません**。これらは AIGateway に残ります。worker は:

- モデルが見る履歴の量を決定しない（AIGateway のステートフル Responses が、圧縮を含めて所有します）;
- 会話を保存しない（AIGateway がします）;
- ターンの副作用がコミットされるかどうかを決定しない（コントロールプレーンがします）。

これこそが worker を交換可能にする分割です。ループを実行するのは worker、トランスクリプトを所有するのは AIGateway、コミットを所有するのはコントロールプレーンです。

## 通信方法

| 方向 | 境界を越えるもの |
|---|---|
| コントロールプレーン → worker | `TurnStart` エンベロープ（actor アイデンティティ、ターン ref、処理するイベント） |
| worker → コントロールプレーン | 進捗エンベロープ（チェックポイント、アクティビティサマリー）、失敗時の `TurnError`、またはターンの自然な完了 |
| worker → AIGateway | モデル呼び出し、関数呼び出し出力（これらはコントロールプレーンを経由しません） |

worker のすべてのメッセージは `ActorTurnRef`（`activation_uid`、`actor_epoch`、`actor_event_id`）を運びます。コントロールプレーンはそれを現在のアクティベーションと照合します。ref がもはや一致しないメッセージは stale として拒否されます。これは [Actor Runtime](../actor-runtime/) トリプルフェンスをターンレベルから見たものです。

## 再試行の境界

ターンが失敗すると、再試行を決定するのは worker ではなくコントロールプレーンです。worker はエラーを報告し、`handle_turn_error` が分類します:

- **再試行可能**（worker 転送の失敗、タイムアウト）— イベントは `open` のまま、エポックが上がり、バックオフ遅延後にランタイムが再配信します。
- **デッドレター** — 5 回の試行（または連続 5 回のターン失敗）後、イベントは `dead_letter` に移り、ターンは再試行を停止します。オペレーターが確認して解決します。

worker は自分で再試行しません。エラーを報告し、再試行の決定はコントロールプレーンが所有します。コントロールプレーンこそがアクティベーションフェンスを再確立できるからです。

## このガイドがそうでないもの

モデルへのプロンプトガイドではありません。ループの形は機械的（呼び出す、実行する、記録する、続ける）であり、その中のモデルの挙動はペルソナの関心事です。転送ガイドでもありません。RuntimeFabric がエンベロープを運び、それは [Kernel](../kernel/) ページの範囲です。そして [Actor Runtime](../actor-runtime/) ページの代わりでもありません。アクティベーションフェンスはターンライフサイクルが内部で動作するコンテキストです。

## 次のステップ

- アクティベーションフェンスと actor モデルについては、[Actor Runtime](../actor-runtime/) を読んでください。
- ループを実行する worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
- ループが呼び出すステートフルな Responses 転送については、[AIGateway](../ai-gateway/) を読んでください。
- 圧縮（worker は所有しない）については、[Context compression](../context-compression-and-caching/) を読んでください。
