---
title: 自動化ブループリント
description: トリガーを Agent session、automation job、background job、signal ルーティングルールと組み合わせ、Workflow との違いを説明します。
section: Guides
order: 309
---

Ankole での自動化は、3 種類のトリガーのいずれかと、2 種類のコンシューマのいずれかを組み合わせます。Agent session は判断、memory、または会話を必要とする作業を処理します。automation job は機械的な処理を決定性スクリプトで実行します。このページでは、よくある形にそのまま使えるブループリントを紹介します。

Automation job は、ワークフロー言語やステップグラフではありません。Agent Home 内にある通常の Bun の `main.ts` です。トリガーの owner が時刻または入り口を管理し続け、選択したコンシューマが変わらないイベントを処理します。Agent が戻るのは、スクリプトがイベントを発火したとき、または失敗ポリシーが Agent を起こしたときだけです。

[Workflow](../workflows/) は別の実行形態です。メイン Agent が Turn の中で、固定された有界のサブエージェント編成を開始します。schedule や webhook のコンシューマではなく、外部状態をポーリングしません。1 回の delivery または会話リクエストに、並行実行できる有限の独立した判断が含まれる場合に使います。

## 3 種類のトリガー

どのブループリントも 3 種類のトリガーのどれかを使います。ブループリントを選ぶ前に、自分に必要なものを把握してください。

| トリガー | 発火の仕方 | キャリア | 何で作る |
|---|---|---|---|
| **Schedule** | cron の頻度で（毎時、毎日、毎週） | cron schedule 上の `task` | [スケジュール](../schedules/) |
| **自己遅延（checkback）** | Agent が turn の中で遅延トリガーを設定する | Agent の `check_back_later` ツール | [スケジュール](../schedules/) |
| **イベント駆動（webhook）** | 外部システムが能力 URL に POST する | `webhook.received` イベント | [Webhook 委譲](../webhook-delegations/) |

3 つとも、Agent を起こす場合もスクリプトを実行する場合も、同じ CloudEvents エンベロープを生成します。コンシューマの選択が変えるのは受信先だけで、トリガーの事実は変わりません。直接の wake と、スクリプトが発火したイベントは、どちらも owner session のルーティングルールを通って戻ってきます。

## コンシューマを選ぶ

| コンシューマ | 使う場面 | トリガーの結果 |
|---|---|---|
| **Agent session** | 各 delivery に判断、memory、実行時に選ぶツール、またはユーザー向けの応答が必要な場合 | トリガーが ActorEvent を追加し、会話を起こします。 |
| **Automation job** | 処理が決定性のある fetch、比較、parse、または事前に決めたアクションである場合 | トリガーが永続的なスクリプト実行を作成します。スクリプトは静かに終了するか、owner session にイベントを発火できます。 |

処理の形がはっきりしない間は、まず Agent を直接起こしてください。機械的であると証明できた部分だけを automation job に移します。こうすることでスクリプトは小さく保たれ、モデルがアイドル状態のポーリングループに入ることもありません。

## ブループリント: 毎日ダイジェスト（schedule）

schedule が 1 日に 1 回 Agent を起こします。Agent は依頼された情報を収集して要約し、結果をバインドされた chat channel に投稿します。[スケジュール](../schedules/) で作成してテストしてから、毎日の cron 式を設定してください。

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "owner_session_id": "<session_id>",
    "binding_name": "main",
    "name": "daily-digest",
    "idempotency_key": "daily-digest-1",
    "schedule": { "kind": "cron", "expression": "0 9 * * *" },
    "timezone": "Asia/Shanghai",
    "delivery": { "targets": [{ "binding_name": "main", "signal_channel_id": "<signal_channel_id>" }] },
    "payload": { "task": "Produce today'\''s digest of the topics in your mission." }
  }'
```

調整できる部分: cron 式（頻度）、`timezone`（"午前 9 時"がどこを指すか）、`task`（何をするか）、そして persona（どうやって行うか）。schedule に頼る前に、手動実行で検証してください。

## ブループリント: 決定性の番兵（schedule + automation job）

schedule が頻繁に発火するものの、確認が機械的で通常は結果がない場合は、automation job を使います。Agent がスクリプトを書き込み、登録し、その `automation_job_id` に cron schedule をバインドします。

```json
{ "kind": "cron", "expression": "0 * * * *" }
```

条件が false のとき、スクリプトはソースを読み取って `emitEvent` なしで終了します。条件が true のときは、バインドされたソースの事実を owner session に発火し、Agent がそれを検証してどうするかを判断します。登録前に SDK を使わないブランチを手動でテストし、`context()` または `emitEvent` を呼ぶすべてのブランチには実際のテストトリガーを使ってください。

毎回の実行に意味的な判断が必要な場合は、Agent を直接起こす schedule のままにしてください。Automation Job の契約は [Worker CLI の能力](../cli-capabilities/) で確認できます。

## ブループリント: 遅延フォローアップ（checkback）

agent が turn の中で何かを尋ねられ、後でそれに戻ることにします。固定の cron ではなく、agent 自身が `check_back_later` で一度だけの wakeup を設定します。agent 側の形は「1 時間後にもう一度見る」です。agent がツールを呼び、運用者側のサーフェスは読み取り専用です。

これは周期を持たない作業に合います。「デプロイが 1 時間後に完了したか確認する」「スタンドアップの後にこの thread を読み直す」などです。タイミングを所有するのは agent であり、保留中の checkback は `GET /api/v1/checkbacks?agent=<agent_uid>` で確認でき、`DELETE /api/v1/agents/:agent_uid/checkbacks/:scheduled_event_id` で 1 つキャンセルできます。

## ブループリント: 調査して報告（schedule + background job）

schedule が turn を開始します。作業に長い検索や相互検証が必要な場合、Agent は turn を開いたままにする代わりに、[Deep Research Background Agent Job](../deep-research-job/) に委譲します。

1. cron schedule がその `task` を発火します。
2. agent は作業が長いと判断し、`create_background_job` を呼びます。
3. schedule の turn が終了し、job が単独で実行されます。
4. job は `background_agent_job.completed` を所有する session に投稿し、binding がそれを配信します。

これが、schedule の turn を 1 時間動かさずに「毎週の deep research」を得る方法です。schedule が蹴り、job が仕事をします。

## ブループリント: イベント駆動（webhook）

ソースリポジトリや CI provider などの外部システムが、短期間有効な Ankole 能力 URL を呼びます。エンドポイントは delivery を受け入れ、成功を返す前に選択したコンシューマのレコードを確定（commit）します。

Agent が現在の外部オブジェクトを検査してイベントを判断しなければならない場合は、既定の直接コンシューマを使います。決定性スクリプトが先に受信内容をフィルタまたは照合できる場合は、エンドポイントを automation job にバインドします。受信内容はどちらの経路でも信頼できない入力であり、結果に影響する事実は常に権威ある外部ソースから取得されます。能力のセキュリティとライフサイクルの規則は [Webhook 委譲](../webhook-delegations/) で確認してください。

## ブループリント: 観察してエスカレーション（binding ポリシー + schedule）

チームアシスタントが channel を監視し、schedule が観察された内容の定期的な要約を生成します。binding ポリシー（`may_intervene` または `record_only`）が agent がリアルタイムで何を見るかを決め、schedule がいつ合成するかを決めます。

- Binding: `unaddressed_group_message_policy: record_only`。agent はすべてを見て、何にも発言せず、context を構築します。
- Schedule: 「この channel で何が起きたか」の毎日または毎週のダイジェスト。
- Agent は session の直近の context を手がかりに、binding を通じて要約を投稿します。

これにより、観察（継続的で静か）と合成（定期で発言あり）が分離されます。リアルタイムの返信がノイズになるが、定期的なダイジェストには価値がある channel に合います。

## ブループリントの選び方

- **時計に合わせて実行したい?** Schedule。毎回投稿するか、何か大事なことが起きたときだけ投稿するかで、ダイジェスト形か番兵形かを選びます。
- **途中で何かに戻りたい?** Checkback。タイミングは agent が所有します。
- **長い作業を時計で始めたい?** Schedule + background job。
- **モデル turn なしで頻繁な機械的チェックをしたい?** Schedule または Checkback + automation job。
- **1 回の Agent Turn から有界の並行判断を始めたい?** Workflow。開始元の会話に集約結果を 1 つ返します。
- **外部システムに作業を続けてもらいたい?** Webhook 委譲。コンシューマは直接 Agent か automation job のどちらかです。
- **静かな観察に加えて定期的な合成が欲しい?** binding ポリシー + schedule。

## Ankole の自動化とはそうでないもの

トリガーによる自動化はワークフロー言語ではありません。YAML のステップ一覧も、プラットフォームの DAG も、隠れたカーソルも、汎用イベントバスもありません。Automation Job は小さなスクリプトを実行できますが、状態と再実行の安全性を所有するのはスクリプト自身です。配信はそれでも owner session のルーティングルールを使い、自動化が権限を迂回することはできません。

製品機能の Workflow も、これらの契約を追加しません。固定 JavaScript で 1 回の有界のサブエージェント fanout を実行し、トリガー subscription を持たず、後からの入力を待てません。判断には Agent、機械的なトリガー処理には Automation Job、有界の並行判断には Workflow を使います。

## 次のステップ

- schedule のサーフェスについては [スケジュール](../schedules/) を読んでください。
- 決定性スクリプトのコンシューマについては [Automation Jobs](../automation-jobs/) を読んでください。
- 有界のサブエージェント編成については [Workflow](../workflows/) を読んでください。
- バックグラウンド実行とコラボレーションの選択肢については [Background Agent Jobs](../background-jobs/) を読んでください。
- 外部イベントの能力については [Webhook 委譲](../webhook-delegations/) を読んでください。
