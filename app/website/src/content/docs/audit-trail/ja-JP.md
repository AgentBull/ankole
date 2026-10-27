---
title: 監査証跡
description: Ankole における監査証跡の読み方。AuthZ の権限付与レコード、control plane の構造化ログ、および各種実行履歴から「誰が・いつ・何を変更したか」を追跡する方法を説明します。
section: Developer guide
order: 125
---

監査証跡とは、「誰が・いつ・何を変更したか」を追跡するための永続的な記録です。Ankole には単一の巨大な監査ログテーブルがあるわけではなく、各サブシステムが自身の責務に関わる重要な決定をそれぞれの監査面に記録します。このページでは、各監査面に何が記録され、それらをどう読み解き、どう組み合わせて調査するかを運用者向けに整理します。

まず押さえておくべき基本原則があります。すべての監査面は**永続化された PostgreSQL の状態または構造化ログ**であり、揮発性のメトリクスではありません。一度書き込まれた記録は書き込んだプロセスが終了しても残りますが、そもそも書き込まれなかった事象を後から復元することはできません。

## AuthZ の付与、人間のアクセス変更、招待の記録

すべての権限付与は `permission_grants` テーブルに永続レコードとして保存されます。各レコードは 1 つの `principal_uid`、1 つの `group_id`、または Userset のページ対象者（`source_page_id` と `source_action`）に紐付き、Pod ACL の付与では `target_page_id` と `target_scope` を通じて `pages` テーブルのレコードを基点とします。何を許可するかは `resource_pattern`、`action`、`condition` で表され、作成日時と最終更新日時がタイムスタンプに記録されます。権限付与のための別建ての監査ログはなく、`permission_grants` テーブルそのものが監査記録を兼ねています。

人間アカウントのライフサイクル変更やワークスペースへの招待についても、PostgreSQL に永続レコードが残ります。

- `human_access_events`: アクセスの無効化、復元、またはディレクトリ同期に伴う状態遷移ごとに、実行者、発生元、変更前後のステータス、`access_version`、および解放された識別子（`released_identifiers`）を記録します。
- `human_access_restrictions`: `:suspended`（一時停止）または `:offboarded`（退職・オフボード）の処分種別（disposition）と理由を持つ、現在有効なアクセス制限を保持します。
- `pod_invitations`: Pod ワークスペースへの招待、メンバーシップ種別（`member` または `guest`）、使用回数（`used_count`）、および作成者（`created_by_principal_uid`）を記録します。

Principal やグループに対する現在の権限付与は、`GET /api/v2/principals/:uid/grants` および `GET /api/v2/principal-groups/:name/grants` から確認できます。一度付与された後に削除された権限を過去にさかのぼって調べる場合は、PostgreSQL のポイントインタイムリカバリ（PITR）履歴を参照します。なお、現在テーブル上に存在するレコードが、まさに今システムで強制されている権限そのものです。

## control-plane の構造化ログ

control plane は一貫したフォーマットの構造化ログを出力します。各ログエントリはイベント名、人間が読めるメッセージ、構造化フィールドで構成され、`debug` から `error` までの重大度（severity）を持ちます。日常的な運用イベントを追う際の監査面となるのがこのログです。

- provider 呼び出し（どの provider のどのモデルを呼び出し、どういう結果になったか）
- Worker のライフサイクル（Worker の起動、Turn の開始、完了またはエラー）
- Signal イベント（何が到着し、フィルタで除外されたか受け入れられたか）
- スケジュールの発火（いつ実行され、どういう結果になったか）

構造化ログは PostgreSQL には保存されず、外部のログ収集基盤（ingester）が受け取った内容がすべてです。監査目的で保持する必要がある場合は、リアルタイムで永続ストア（ログ検索インデックスや S3 アーカイブなど）へ転送してください。転送されなかったログはプロセスの終了とともに失われます。

ログ出力の設定については [Environment variables](../environment-variables/) を、具体的なログの読み方については [Ankole のログを読む](../log-reading/) を参照してください。

## Signal と delivery の行

セッションを起動する永続受信箱であるすべての Signal と、外部へのすべての delivery（配信）試行も PostgreSQL のレコードとして保存されます。これらは実行制御のための運用状態であると同時に、「システムに何が依頼され、実際に外部へ配信されたかどうか」を示す確かな証跡にもなります。また、Console API の `/api/v2/background-agent-jobs/:id` ルートからはジョブの試行回数（`attempts`）と `error` を確認でき、`/api/v2/ai-gateway/conversations` ルートからは各 Turn で実行されたモデル呼び出しの履歴を確認できます。

## 組み合わせて使う

実際の監査や調査では、複数の記録面を組み合わせて確認するのが一般的です。

| 問い | 確認先 |
|---|---|
| 「誰がこの Agent またはページ対象者に Y の権限を与えたのか？」 | `permission_grants` + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| 「なぜこの人間アカウントが一時停止・オフボード・招待されたのか？」 | `human_access_events`、`human_access_restrictions`、`pod_invitations` |
| 「この Turn で Agent は具体的に何をしたのか？」 | `/api/v2/ai-gateway/conversations/:id/messages` |
| 「スケジュールは予定どおり発火したか？」 | `/api/v2/cron-schedules/:id/runs` |
| 「失敗したジョブはリトライされたか？」 | `/api/v2/background-agent-jobs/:id`（`attempts`、`error`） |
| 「その時点で Worker や control plane は何をログに出していたか？」 | control plane の構造化ログ |

## このガイドではないもの

このページは特定のコンプライアンス基準そのものを定義するものではありません。Ankole は記録の仕組みを提供しますが、保持期間などの運用ルールは各組織のコンプライアンスポリシーに従って定めてください。また、特定製品の SIEM 連携ガイドでもありません（ログは標準的な構造化 JSON で出力されるため、任意の収集基盤を選択できます）。さらに、バックアップと復元テストの代わりにもなりません。主要な監査証跡は PostgreSQL 内に格納されているため、データベースを復元できなければ監査証跡も一緒に失われます。

## 次のステップ

- 権限モデルの詳細については、[Principal and AuthZ](../principal-authz/) を参照してください。
- ログ設定とトラブルシューティング手順については、[Environment variables](../environment-variables/) および [Ankole のログを読む](../log-reading/) を参照してください。
- 監査証跡を保護するバックアップ運用については、[Backup and restore](../backup-and-restore/) を参照してください。
