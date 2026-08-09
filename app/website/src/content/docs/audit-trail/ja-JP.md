---
title: 監査証跡
description: Ankole の監査面の読み方——Brain の監査記録、control-plane の構造化ログ、そしてそれぞれが誰がいつ何を変えたかをどう記録するか。
section: Developer guide
order: 125
---

監査証跡とは、誰がいつ何を変えたかについての永続的な記録です。Ankole には単一の監査ログはありません。複数の面があり、それぞれを別のサブシステムが所有し、それぞれが自分にとって重要な決定を記録します。このページは、それらの面についてのオペレーター用の地図です。それぞれが何を記録するか、どう読むか、どう組み合わせて使うか。

決定的な性質を先に述べます。すべての監査面は**永続的な PostgreSQL 状態または構造化ログ**であり、一時的なメトリクスではありません。書き込まれた記録は、それを書いたプロセスより長く生き残ります。書き込まれなかった記録は再構成できません。

## Brain の監査記録

最も構造化された監査面です。Brain へのすべての知識書き込み——新しいエントリ、ブロック編集、削除、復元——が append-only の監査行を生成します。読み取りは次のように行います:

```bash
curl https://ankole.example.com/api/v1/brain/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

あるいは 1 つのエントリに絞り込むには:

```bash
curl https://ankole.example.com/api/v1/brain/entries/<id>/audit-log \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

各行は、誰が変更したか（actor）、どの種類の actor か（human、agent、dreaming、source_learning、mechanical）、どの操作が実行されたか、そしていつかを記録します。復元自体も監査されます——以前の状態への復元は新しい監査行を追加し、取り消される変更を作った行を消しません。

これは「なぜ Agent はそう信じているのか」という問いのための面です。答えは監査証跡にあり、model の現在の出力にはありません。

## AuthZ の付与記録

すべての権限付与は `permission_grants` の永続的な行です。付与の `principal_uid` または `group_id` が所有者を示し、`resource_pattern` と `action` が許可される内容を示し、タイムスタンプが作成時刻と最終更新時刻を記録します。付与に別の監査ログはありません——付与テーブル自体が記録です。付与は基本的に追加のみであり、変更は行の更新として見えるためです。

付与の読み取りは `GET /principals/:uid/grants` と `GET /principal-groups/:name/grants` を通じて行います。追加されて後に削除された付与は、テーブルの履歴に現れます（PostgreSQL の point-in-time recovery を維持している場合）。現在存在する付与が、システムが強制する内容です。

## control-plane の構造化ログ

control plane は安定した形状の構造化ログを出力します。イベント名、人間向けのメッセージ、構造化フィールドで、重大度は `debug` から `error` までです。これらは運用イベントの監査面です。

- provider 呼び出し（どの provider、どの model、結果）
- worker ライフサイクル（worker 起動、Turn 開始、Turn 完了またはエラー）
- signal イベント（何が届いたか、フィルタリングされたか受け入れられたか）
- schedule の発火（いつ、どのような結果か）

ログは PostgreSQL ではありません——ログは、ログ ingester が受信するものをそのまま扱います。監査に使う必要があるなら、リアルタイムで永続ストア（ログインデックス、S3 アーカイブ）に送ってください。送られなかったログはプロセスと共に消えます。

ログ設定は [Environment variables](../environment-variables/)、診断方法は [Ankole のログを読む](../log-reading/) を参照してください。

## actor-event と delivery の行

すべての actor event（セッションを駆動する永続的な inbox）と、すべての delivery 試行は PostgreSQL の行です。これらは通常、監査のために読まれるものではありません——運用状態です——しかし、システムが何をするよう求められたか、配信されたかどうかの記録を形成します。Console の `/background-agent-jobs/:id` ルートは job の `attempts` と `error` を表示し、`/ai-gateway/conversations` ルートは Turn が行った model 呼び出しを表示します。

## 組み合わせて使う

実際の監査の問いは、通常複数の面にまたがります。

| 問い | どこを見るか |
|---|---|
| 「Agent はなぜ X を信じているのか?」 | Brain の監査記録 |
| 「誰がこの Agent に Y をする権限を与えたのか?」 | `permission_grants` + `/principals/:uid/grants` |
| 「この Turn で Agent は何をしたのか?」 | `/ai-gateway/conversations/:id/messages` |
| 「schedule は発火したか?」 | `/cron-schedules/:id/runs` |
| 「job の失敗は再試行されたか?」 | `/background-agent-jobs/:id`（`attempts`、`error`） |
| 「そのとき worker は何をログに記録したか?」 | control-plane の構造化ログ |

## このガイドではないもの

これはコンプライアンスフレームワークではありません——Ankole は面を提供し、保持期間を決めるのはあなたのコンプライアンス方針です。SIEM 統合ガイドでもありません——ログは構造化 JSON であり、ingester はあなたの選択です。そして、テスト済みバックアップの代わりでもありません——監査証跡は PostgreSQL にあり、復元できないデータベースは証跡も道連れに失われます。

## 次のステップ

- Brain の監査面については、[Brain](../brain/) を読んでください。
- 権限モデルについては、[Principal and AuthZ](../principal-authz/) を読んでください。
- ログ設定と診断については、[Environment variables](../environment-variables/) と [Ankole のログを読む](../log-reading/) を読んでください。
- 証跡を守るバックアップについては、[Backup and restore](../backup-and-restore/) を読んでください。