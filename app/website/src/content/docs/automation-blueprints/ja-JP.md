---
title: 自動化ブループリント
description: トリガーを Agent session、automation job、background job、signal ルーティングルールと組み合わせる実践パターンと、Workflow との使い分けを説明します。
section: Guides
order: 309
---

Ankole における自動化は、「3 種類のトリガー」のいずれかと「2 種類のコンシューマ」のいずれかを組み合わせて構成します。コンシューマのうち、Agent session は判断・長期記憶・対話が必要な作業を担当し、automation job は定型的な処理を決定論的なスクリプトで実行します。このページでは、よくある運用パターンにそのまま適用できるブループリントを紹介します。

なお、Automation job は専用のワークフロー言語やステップグラフではなく、Agent のドライブ上のフォルダーに配置する通常の Bun 製 `main.ts` スクリプトです。実行スケジュールや受信窓口はトリガー側の管理下に残ったまま、選択したコンシューマがイベントを受け取って処理します。Agent が起動されるのは、スクリプトが明示的にイベントを発火したとき、または失敗時のポリシーによって呼び出されたときだけです。

一方、[Workflow](../workflows/) はこれらとは異なる実行形態です。メイン Agent が 1 回の Turn の中で、あらかじめ段階が定まった上限付きのサブエージェント編成を開始します。schedule や webhook の受け皿にはならず、外部状態のポーリングも行いません。1 回の受信イベントや会話リクエストの中に、並行して処理できる有限個の独立した判断が含まれる場合に使用します。

## 3 種類のトリガー

どのブループリントも、次の 3 種類のトリガーのいずれかを起点にします。まずは用途に合うトリガーを選んでください。

| トリガー | 発火の仕組み | キャリア | 設定手段 |
|---|---|---|---|
| **Schedule** | cron の周期（毎時・毎日・毎週など）で発火 | cron schedule 上の `task` | [スケジュール](../schedules/) |
| **自己遅延（checkback）** | Agent が turn の中で将来の再確認タイマーを設定 | Agent の `check_back_later` ツール | [スケジュール](../schedules/) |
| **イベント駆動（webhook）** | 外部システムが capability URL へ POST | `webhook.received` イベント | [Webhook 委譲](../webhook-delegations/) |

3 種類のトリガーはいずれも、Agent を直接起こす場合でもスクリプトを実行する場合でも、共通の CloudEvents エンベロープを生成します。コンシューマの選択によって変わるのはイベントの受け取り先だけであり、トリガー自体の記録は変わりません。また、Agent を直接起こした場合もスクリプトがイベントを発火した場合も、最終的な配信は owner session のルーティングルールを通ります。

## コンシューマを選ぶ

| コンシューマ | 向いている場面 | トリガー発火時の動作 |
|---|---|---|
| **Agent session** | 各イベントの処理に文脈判断、記憶の参照、動的なツール選択、または人間向けの応答が必要な場合 | Signal がキューに追加され、対象の会話セッションが起動します。 |
| **Automation job** | 処理内容が定型的なデータ取得、比較、パース、または事前に決まったアクションである場合 | 永続管理されるスクリプト実行が開始されます。スクリプトは何もせず静かに終了することも、owner session へイベントを発火することもできます。 |

処理手順がまだ固まりきっていない段階では、まず Agent session を直接起こす構成から始めてください。その後、完全に機械的な処理だと確認できた部分だけを automation job へ切り出すことで、スクリプトをシンプルに保ちつつ、モデルが変化のないポーリングで無駄に稼働するのを防げます。

## ブループリント: 毎日ダイジェスト（schedule）

1 日 1 回スケジュールで Agent を起こし、指定したトピックの情報を集めて要約を作成させ、紐付けられたチャットチャネルへ投稿させるパターンです。[スケジュール](../schedules/)を作成したら、毎日の cron 式に任せる前にまず手動実行で動作を確認してください。

以下の Console API リクエストを送る際は、事前にログイン済みブラウザーからセッション Cookie と `x-csrf-token` の値を取得してください。

```bash
curl -X POST https://ankole.example.com/api/v2/agents/<agent_uid>/cron-schedules \
  -H "Cookie: $CONSOLE_COOKIE" \
  -H "x-csrf-token: $CSRF_TOKEN" \
  -H "Content-Type: application/vnd.api+json" \
  -d '{
    "data": {
      "owner_session_id": "<session_id>",
      "binding_name": "main",
      "name": "daily-digest",
      "idempotency_key": "daily-digest-1",
      "schedule": { "kind": "cron", "expression": "0 9 * * *" },
      "timezone": "Asia/Shanghai",
      "delivery": { "targets": [{ "binding_name": "main", "conversation_id": "<conversation_uuid>" }] },
      "payload": { "task": "Produce today'\''s digest of the topics in your mission." }
    }
  }'
```

調整のポイントは、cron 式（実行頻度）、`timezone`（「午前 9 時」をどのタイムゾーンで解釈するか）、`task`（何をまとめるか）、および Agent のペルソナ設定（どのようなトーンや形式で書くか）です。定期実行の本番運用に入る前に、一度手動トリガーで出力を確認しておくことをおすすめします。

## ブループリント: 決定性の番兵（schedule + automation job）

高い頻度でチェックしたいものの、確認手順自体は機械的で大半の回は何も異常がない——そのようなケースには automation job が適しています。Agent にスクリプトを書かせて登録し、その `automation_job_id` に cron スケジュールを紐付けます。

```json
{ "kind": "cron", "expression": "0 * * * *" }
```

監視条件に該当しない場合、スクリプトは対象ソースを確認したあと `emitEvent` を呼ばずにそのまま終了します。条件に一致したときだけ、確認した事実を owner session へイベント発火し、それを受けた Agent が内容を精査して対応を判断します。登録前には SDK に依存しないロジック部分を手動テストし、`context()` や `emitEvent` を呼ぶ分岐については実際のテストトリガーを使って検証してください。

なお、毎回のチェック自体に意味的な解釈や判断が必要な場合は、スクリプトを挟まず Agent を直接起こすスケジュールのままにしてください。Automation Job の仕様詳細は [Worker CLI の能力](../cli-capabilities/)で確認できます。

## ブループリント: 遅延フォローアップ（checkback）

会話の途中で依頼を受けた Agent が、「少し時間を置いてからもう一度確認する」と判断したときに使うパターンです。固定の cron スケジュールを組むのではなく、Agent 自身が `check_back_later` ツールを呼んで 1 回限りの起動タイマーをセットします。運用者向けの API は確認・キャンセル専用であり、タイマー自体の作成は Agent がツール経由で行います。

「1 時間後にデプロイが無事完了したか確認する」「朝会のあとにこのスレッドを読み直す」といった単発のフォローアップに最適です。スケジュール時刻は Agent 自身が管理し、待機中の checkback は `GET /api/v2/checkbacks?agent=<agent_uid>` で一覧確認できるほか、`DELETE /api/v2/agents/:agent_uid/checkbacks/:scheduled_event_id` で個別にキャンセルできます。

## ブループリント: 調査して報告（schedule + background job）

スケジュールで Turn を開始したあと、長時間の検索や複数情報源の突き合わせが必要な作業を [Deep Research Background Agent Job](../deep-research-job/) へ委任するパターンです。スケジュールの Turn 自体を長時間開きっぱなしにする必要がありません。

1. cron スケジュールが発火し、指定された `task` で Agent が起動します。
2. Agent が「長時間の調査が必要」と判断し、`create_background_job` を呼び出します。
3. スケジュール側の Turn はいったん終了し、以降は Background Agent Job が独立して調査を進めます。
4. 調査が完了すると、Job が owner session へ `background_agent_job.completed` を送り、紐付けられたチャネルへ結果が配信されます。

スケジュール Turn を 1 時間占有することなく「毎週の Deep Research レポート」を実現したい場合は、この構成を使います。スケジュールは開始のきっかけを作るだけで、実作業はすべてジョブ側が引き受けます。

## ブループリント: イベント駆動（webhook）

Git リポジトリや CI サービスなどの外部システムから、有効期限付きの Ankole capability URL を呼び出してもらうパターンです。エンドポイントはリクエストを受信すると、選択されたコンシューマ向けの永続レコードをコミットしてから成功レスポンスを返します。

イベントの解釈に外部オブジェクトの最新状態確認や文脈判断が欠かせない場合は、既定の「Agent session 直接起動」を使います。逆に、受信ペイロードのフィルタリングや照合を決定論的なコードで先に済ませられる場合は、エンドポイントを automation job に紐付けます。なお、いずれの経路でも受信ペイロード自体は信頼できない外部入力として扱われるため、意思決定に関わる重要な事実は必ず信頼できる外部の正本ソースから再取得して裏付けを取ります。セキュリティおよびライフサイクルの詳細は [Webhook 委譲](../webhook-delegations/)を参照してください。

## ブループリント: 観察してエスカレーション（binding ポリシー + schedule）

チームアシスタントに普段はチャンネルの会話を静かに見守らせ、決まった時刻にその期間のやり取りを要約させるパターンです。リアルタイムでどのメッセージを取り込むかは binding ポリシー（`may_intervene` または `record_only`）で制御し、いつ要約を作るかは schedule で制御します。

- **Binding 設定**: `unaddressed_group_message_policy: record_only` に設定します。Agent はチャンネル内の発言をすべて記録して文脈を蓄積しますが、その場では一切発言しません。
- **Schedule 設定**: 「今日（今週）このチャンネルで何が起きたか」をまとめる日次・週次ダイジェストを設定します。
- **出力**: スケジュール発火時に、蓄積されたセッションの直近コンテキストをもとに Agent が要約を作成し、同じ binding を通じてチャンネルへ投稿します。

このように「継続的かつ静かな観察」と「定期的な要約の発信」を切り離せるため、都度の返信はノイズになるものの定期サマリーは重宝される活発なチャンネルに適しています。

## ブループリントの選び方

- **決まった時刻に定期実行したい:** Schedule を選びます。毎回レポートを出すなら「毎日ダイジェスト」、異常時だけ知らせるなら「決定性の番兵」を使います。
- **今の会話の延長で、あとからもう一度確認させたい:** Checkback を選びます。タイミングは Agent 自身が設定します。
- **時間のかかる調査を定期実行したい:** Schedule + background job を組み合わせます。
- **モデルを動かさずに高頻度の機械的チェックを行いたい:** Schedule または Checkback に automation job を組み合わせます。
- **1 回の Agent Turn から上限付きの並列判断を実行したい:** Workflow を選びます。集約された結果が元の会話に 1 つ返ります。
- **外部システムのイベントをきっかけに処理を走らせたい:** Webhook 委譲を選び、コンシューマには Agent 直接起動または automation job を指定します。
- **普段は発言せずに会話を記録し、定期的にまとめたい:** binding ポリシー（`record_only`）+ Schedule を組み合わせます。

## Ankole の自動化とはそうでないもの

トリガーベースの自動化は独自のワークフロー記述言語ではありません。YAML によるステップ定義も、プラットフォーム管理の DAG も、暗黙のカーソル管理も、汎用イベントバスも存在しません。Automation Job では小さなスクリプトを実行できますが、状態管理や再実行時の安全性（冪等性）はスクリプト側で担保します。また、結果の配信は常に owner session のルーティングルールを経由するため、自動化によって権限境界をバイパスすることはできません。

製品機能の Workflow もこれらの境界を変えるものではありません。固定された JavaScript で 1 回限りの上限付きサブエージェント fanout を実行する機能であり、トリガーの購読や後続メッセージの待機は行いません。文脈判断には Agent、定型的なトリガー処理には Automation Job、上限付きの並列判断には Workflow を使い分けてください。

## 次のステップ

- スケジュール設定の詳細については、[スケジュール](../schedules/)を参照してください。
- 決定論的スクリプトを実行するコンシューマについては、[Automation Jobs](../automation-jobs/)を参照してください。
- 上限付きのサブエージェント編成については、[Workflow](../workflows/)を参照してください。
- バックグラウンドでの長時間実行と対話連携については、[Background Agent Jobs](../background-jobs/)を参照してください。
- 外部イベントを受け取る capability URL については、[Webhook 委譲](../webhook-delegations/)を参照してください。
