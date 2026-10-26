---
title: 監査証跡
description: Ankole の監査面の読み方——AuthZ の付与記録、control-plane の構造化ログ、そしてそれぞれが誰がいつ何を変えたかをどう記録するか。
section: Developer guide
order: 125
---

監査証跡とは、誰がいつ何を変えたかについての永続的な記録です。Ankole には単一の監査ログはありません。複数の面があり、それぞれを別のサブシステムが所有し、それぞれが自分にとって重要な決定を記録します。このページは、それらの面についてのオペレーター用の地図です。それぞれが何を記録するか、どう読むか、どう組み合わせて使うか。

決定的な性質を先に述べます。すべての監査面は**永続的な PostgreSQL 状態または構造化ログ**であり、一時的なメトリクスではありません。書き込まれた記録は、それを書いたプロセスより長く生き残ります。書き込まれなかった記録は再構成できません。

## AuthZ の付与、人間のアクセス変更、招待の記録

すべての権限付与は `permission_grants` の永続的な行です。各付与は 1 つの `principal_uid`、1 つの `group_id`、または Userset のページ対象者（`source_page_id` と `source_action`）に属し、Pod ACL の付与は `target_page_id` と `target_scope` を通じて `pages` テーブルの行をアンカーとします。`resource_pattern`、`action`、`condition` が許可される内容を示し、タイムスタンプが作成時刻と最終更新時刻を記録します。付与に別の監査ログはありません——`permission_grants` テーブル自体が記録です。

人間アカウントのライフサイクル変更とワークスペースへの招待も、永続的な PostgreSQL の行を記録します。

- `human_access_events` は、各アクセスの無効化、復元、またはディレクトリ同期による状態遷移を、実行者、出所、変更前後のステータス、`access_version`、および解放された識別子（`released_identifiers`）とともに記録します。
- `human_access_restrictions` は、`:suspended`（一時停止）または `:offboarded`（退職・オフボード）の処分（disposition）と理由を持つ有効な制限を保持します。
- `pod_invitations` は、Pod ワークスペースへの招待、メンバーシップ種別（`member` または `guest`）、使用数（`used_count`）、および作成者（`created_by_principal_uid`）を記録します。

Principal およびグループの付与の読み取りは `GET /api/v2/principals/:uid/grants` と `GET /api/v2/principal-groups/:name/grants` を通じて行います。追加されて後に削除された付与は、PostgreSQL の point-in-time recovery 履歴に現れます。現在存在する行が、システムが強制する内容です。

## control-plane の構造化ログ

control plane は安定した形状の構造化ログを出力します。イベント名、人間向けのメッセージ、構造化フィールドで、重大度は `debug` から `error` までです。これらは運用イベントの監査面です。

- provider 呼び出し（どの provider、どの model、結果）
- worker ライフサイクル（worker 起動、Turn 開始、Turn 完了またはエラー）
- signal イベント（何が届いたか、フィルタリングされたか受け入れられたか）
- schedule の発火（いつ、どのような結果か）

ログは PostgreSQL ではありません——ログは、ログ ingester が受信するものをそのまま扱います。監査に使う必要があるなら、リアルタイムで永続ストア（ログインデックス、S3 アーカイブ）に送ってください。送られなかったログはプロセスと共に消えます。

ログ設定は [Environment variables](../environment-variables/)、診断方法は [Ankole のログを読む](../log-reading/) を参照してください。

## Signal と delivery の行

すべての Signal（セッションを駆動する永続的な inbox）と、すべての delivery 試行は PostgreSQL の行です。これらは運用状態であると同時に、システムが何をするよう求められたか、配信されたかどうかの記録を形成します。Console API の `/api/v2/background-agent-jobs/:id` ルートは job の `attempts` と `error` を表示し、`/api/v2/ai-gateway/conversations` ルートは Turn が行った model 呼び出しを表示します。

## 組み合わせて使う

実際の監査の問いは、通常複数の面にまたがります。

| 問い | どこを見るか |
|---|---|
| 「誰がこの Agent またはページ対象者に Y をする権限を与えたのか?」 | `permission_grants` + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| 「なぜ人間アカウントが一時停止、オフボード、または招待されたのか?」 | `human_access_events`、`human_access_restrictions`、`pod_invitations` |
| 「この Turn で Agent は何をしたのか?」 | `/api/v2/ai-gateway/conversations/:id/messages` |
| 「schedule は発火したか?」 | `/api/v2/cron-schedules/:id/runs` |
| 「job の失敗は再試行されたか?」 | `/api/v2/background-agent-jobs/:id`（`attempts`、`error`） |
| 「そのとき worker は何をログに記録したか?」 | control-plane の構造化ログ |

## このガイドではないもの

これはコンプライアンスフレームワークではありません——Ankole は面を提供し、保持期間を決めるのはあなたのコンプライアンス方針です。SIEM 統合ガイドでもありません——ログは構造化 JSON であり、ingester はあなたの選択です。そして、テスト済みバックアップの代わりでもありません——監査証跡は PostgreSQL にあり、復元できないデータベースは証跡も道連れに失われます。

## 次のステップ

- 権限モデルについては、[Principal and AuthZ](../principal-authz/) を読んでください。
- ログ設定と診断については、[Environment variables](../environment-variables/) と [Ankole のログを読む](../log-reading/) を読んでください。
- 証跡を守るバックアップについては、[Backup and restore](../backup-and-restore/) を読んでください。