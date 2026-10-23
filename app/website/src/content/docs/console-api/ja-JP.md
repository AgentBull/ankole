---
title: Console API リファレンス
description: Console が使用する /api/v1 と /api/v2 API のリファレンス。認証、リソースの route、authorization action を含みます。
section: Reference
order: 203
---

Console REST API は browser session cookie を使用します。`RequireSiteAdminSession` は各 request で Console context、Human の失効状態、現在の site administrator membership を確認します。認証に失敗すると `401` を返します。GET と HEAD 以外の request は shell の `x-csrf-token` header が必要です。CSRF 証明がない場合、または無効な場合は `403` を返します。

表には各 route の完全なパスを示します。Console API には 2 つの version があります。

- `/api/v2` の route は JSON:API（`application/vnd.api+json`）を使用します。一覧 route は `page[limit]` と `page[after]` による keyset pagination を使用します。フィールドのエラーは `400` を返します。レコードが存在しない場合は `404` と `not_found` を返します。現在の状態と競合する場合は `409`、その他の domain による拒否は `422` を返します。エラーの `code` は理由の名前です。
- `/api/v1` の route は `application/json` を使用します。集約ビュー、secret、プロトコル操作、ファイル転送、stream を提供します。

site 管理 route は `/api/v2/site` と `/api/v1/site` にあり、`:session_api` + `:site_admin` pipeline を使用します。tenant データ route は `/api/v2` と `/api/v1` にあり、 `:session_api` + `:site_admin` + `:data_context` pipeline と `PutDataContext` を使用します。tenant route では `x-ankole-tenant: <tenant UUID>` でデータの tenant を選択します。ヘッダを省略すると呼び出し元の tenant を使用します。無効、利用不可、または削除中の tenant は `404` と `data_tenant_unavailable` を返します。このヘッダは呼び出し元の identity や site 管理権限を変更せず、site route の scope も選択しません。

公開 `/api/v1/openapi.json` は v1 route を記述します。`/api/v2/openapi.json` と `/api/v2/site/openapi.json` は v2 route を記述し、それらの route と同じ認証が必要です。runtime AI 呼び出しと webhook はそれぞれの認証規則を使用します。

## configuration の surface

configuration は controller 単位ではなく、「何を構成するか」で整理されています。運用者が実際に操作する surface は次のとおりです。

### Provider と model アクセス

稼働中の agent には背後に model が必要です。運用者は AIGateway の provider surface と agent の model profile を通じてそれを接続します。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/ai-gateway/provider-kinds` | この deployment instance が構成できる provider kind を一覧表示 |
| `GET` | `/api/v1/site/ai-gateway/models` | Console 設定用に capability 付き provider model を一覧表示 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 構成済みの provider を一覧表示 |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 1 つの provider とその credential pool の状態を読み取る |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | provider を作成または置換 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | provider を削除 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials` | credential pool のメンバーを追加 |
| `PUT` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | pool メンバーを更新または再認証 |
| `DELETE` | `/api/v1/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | pool メンバーを削除 |
| `PUT` | `/api/v1/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | pool の選択 strategy を設定 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT の device または browser ログインを 1 回開始 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | device ログインを 1 回 poll |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | ブラウザ貼り付けの代替経路を完了 |
| `POST` | `/api/v1/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Enterprise access token を追加 |
| `GET` | `/api/v1/agents/:agent_uid/model-profiles` | agent の model profile を一覧表示 |
| `PUT` | `/api/v1/agents/:agent_uid/model-profiles/:profile` | profile を作成または置換 |
| `DELETE` | `/api/v1/agents/:agent_uid/model-profiles/:profile` | profile を削除 |

Provider の credential は暗号化された pool メンバーとして control plane に置かれ、agent の環境には決して置かれません。model profile は agent を provider と model に bind します。AIGateway はその provider 内で健全なメンバーを選択し、projection は安全な account 情報、健康状態、rate limit データ、使用量だけを返します。

### Agent とその能力

agent は、運用者が他のすべてを構成する際の単位です。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/agents` | agent を一覧表示 |
| `POST` | `/api/v2/agents` | agent を作成 |
| `GET` | `/api/v2/agents/:agent_uid` | 1 つの agent を読み取る |
| `PATCH` | `/api/v2/agents/:agent_uid` | agent を更新 |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 無効化された agent を再有効化 |
| `DELETE` | `/api/v2/agents/:agent_uid` | 有効な agent を無効化し、無効化済みの agent は完全に削除 |

### Worker provider

各 Agent は作成時に Worker provider を選択し、その後は変更できません。Provider の YAML 設定と暗号化された credential は別々に保存します。ライフサイクルとストレージの契約は [Worker 管理](../worker-management/)を参照してください。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/worker-provider-kinds` | provider kind、YAML の例、credential 要件を一覧表示 |
| `GET` | `/api/v2/site/worker-providers` | 設定済み Worker provider を一覧表示 |
| `POST` | `/api/v2/site/worker-providers` | Worker provider を作成 |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 設定または credential を更新 |
| `GET` | `/api/v1/site/worker-providers/:provider_id/check` | 接続と権限を確認 |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | Agent が使用していない provider を削除 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 移行後に provider が未設定の Agent に割り当て |

### signal routing rule

signal routing rule（API schema では `Signal Binding`）は provider adapter を Agent に接続し、共有された仕事が Agent に届くようにします。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/signal-adapters` | この deployment instance が宣言した adapter を一覧表示 |
| `GET` | `/api/v1/signal-bindings` | routing rule を一覧表示（`?agent=` で Agent を絞り込み） |
| `PUT` | `/api/v1/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | routing rule を作成または置換 |
| `PATCH` | `/api/v1/agents/:agent_uid/signal-bindings/:binding_name` | routing rule を更新 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | routing rule を無効化 |
| `GET` | `/api/v1/conversations/:conversation_id/standing-orders` | 1 つの Conversation の standing orders を読み取る |
| `PUT` | `/api/v1/conversations/:conversation_id/standing-orders` | 1 つの Conversation の standing orders を置換 |

binding を無効にすると、binding を削除せずに、新しい signal が agent を wake しなくなります。

### Agent Library の能力

Library のデフォルトは選択した tenant に属します。Agent の override もその tenant 内で適用します。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/agent-library/capabilities` | tenantな library 能力を一覧表示 |
| `PUT` | `/api/v1/agent-library/agent-plugins/:id` | plugin のtenantな既定状態を設定 |
| `PUT` | `/api/v1/agent-library/skills/:id` | skill のtenantな既定状態を設定 |
| `GET` | `/api/v1/agents/:agent_uid/library-capabilities` | agent の実効能力を一覧表示 |
| `PUT` | `/api/v1/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 1 つの agent に対して plugin を override |
| `PUT` | `/api/v1/agents/:agent_uid/library-capabilities/skills/:id` | 1 つの agent に対して skill を override |
| `GET` | `/api/v1/agents/:agent_uid/library-documents` | agent の library document を一覧表示 |
| `PUT` | `/api/v1/agents/:agent_uid/library-documents/:document_kind` | library document を設定 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 有効な Skill 教訓と廃止済み教訓を一覧表示 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 有効な Skill に人の教訓を追加 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 教訓を廃止 |

能力はまずtenantに有効化され、その後 Agent ごとに狭めたり広げたりできます。Skill 教訓は Skill source を変更せずに、1 つの Agent へ追加の作業指針を渡します。一覧には証拠と廃止履歴も含まれます。廃止された教訓は配信されず、人が取り消した内容は Dreaming の再学習禁止 list に残ります。lifecycle と制限については [Skill 教訓](../skill-lessons/) を参照してください。

### 環境変数（WorkerEnv）

WorkerEnv は site のデフォルト、tenant の override、Agent への割り当てを持ちます。次の route は metadata を返します。平文の取得は別の audit 対象の復号操作です。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/worker-envs` | site デフォルトを一覧表示 |
| `PUT` | `/api/v1/site/worker-envs/:name` | site デフォルトを設定 |
| `DELETE` | `/api/v1/site/worker-envs/:name` | site デフォルトを削除 |
| `POST` | `/api/v1/site/worker-envs/:name/decryptions` | site 値を復号 |
| `GET` | `/api/v1/worker-envs` | tenant 値を一覧表示 |
| `PUT` | `/api/v1/worker-envs/:name` | tenant 値を設定 |
| `DELETE` | `/api/v1/worker-envs/:name` | tenant 値を削除 |
| `POST` | `/api/v1/worker-envs/:name/decryptions` | tenant 値を復号 |
| `GET` | `/api/v1/agents/:agent_uid/worker-envs` | Agent の割り当てを一覧表示 |
| `PUT` | `/api/v1/agents/:agent_uid/worker-envs/:name` | Agent に値を割り当てまたは override |
| `DELETE` | `/api/v1/agents/:agent_uid/worker-envs/:name` | Agent の割り当てを削除 |
| `POST` | `/api/v1/agents/:agent_uid/worker-envs/:name/decryptions` | Agent 値を復号 |

Agent の割り当ては専用値を使用するか、tenant 値、site デフォルトの順で継承します。Worker の作業開始時に環境を解決します。既存の workspace は作成時の環境を保持します。

### Control Plane Plugin

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/site/control-plane-plugins` | Control Plane Plugin とその状態を一覧表示 |
| `PUT` | `/api/v1/site/control-plane-plugins` | plugin を有効化または無効化 |

Control Plane Plugin は、signals adapter のように、control plane 自身の動作を変えるファーストパーティ拡張です。

### Identity provider と AppConfiguration

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v1/identity-provider-adapters` | この deployment instance がサポートする IdP adapter を一覧表示 |
| `GET` | `/api/v1/identity-providers` | 構成済みの identity provider を一覧表示 |
| `PUT` | `/api/v1/identity-providers/:provider_id` | IdP を作成または置換 |
| `POST` | `/api/v1/identity-providers/:provider_id/sync-runs` | IdP から directory group を同期 |
| `GET` | `/api/v1/site/app-configurations` | site configuration key を一覧表示 |
| `PUT` | `/api/v1/site/app-configurations/:key` | site 値を設定 |
| `POST` | `/api/v1/site/app-configurations/:key/decryptions` | site secret を復号 |
| `GET` | `/api/v1/app-configurations` | 運用者が管理する configuration key を一覧表示 |
| `PUT` | `/api/v1/app-configurations/:key` | configuration の値を設定 |
| `POST` | `/api/v1/app-configurations/:key/decryptions` | 1 つの secret configuration 値を復号 |

`AppConfiguration` は宣言済みの運用設定を site または tenant scope で保存します。`/api/v1/site/app-configurations` は site key、`/api/v1/app-configurations` は tenant key を管理します。どちらも一覧、単一 key の読み取り、設定、override の削除、audit 対象の復号をサポートします。起動時の credential と事実は環境変数または secret mount に置きます。

### Tenant 管理

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | tenant を一覧表示 |
| `POST` | `/api/v2/site/tenants` | tenant を作成 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | tenant を更新 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | tenant の削除を要求 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | tenant を停止 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | tenant を再開 |
| `GET` | `/api/v2/site/privileged-tenant` | privileged tenant を読み取る |
| `PATCH` | `/api/v2/site/privileged-tenant` | 別の tenant に site 管理を移管 |

## 読み取り用の surface

configuration に加えて、Console はシステムの残りの部分に対する observability の経路でもあります。既に解説した各 subsystem は、ここに読み取り用の surface を持ちます。

- **処理中の Agent**: `/api/v1/agents/:agent_uid/sessions`。Agent ごとの cron schedule と checkback の管理。一覧エンドポイントはtenant 全体で、`agent` フィルターを取ります。
- **Worker**: `/api/v2/agent-workers` で各 Agent の Worker 状態を一覧表示します。
- **Agent drive**: `/api/v1/agents/:agent_uid/files` でファイルの一覧表示、アップロード、削除、`/api/v1/agents/:agent_uid/files/content` でダウンロード、`/api/v1/agents/:agent_uid/file-moves` で移動します。これらのファイルは control plane が管理します。
- **Job**: `/api/v2/background-agent-jobs`（一覧表示、読み取り、cancel）。
- **AI の活動**: `/api/v2/ai-gateway/conversations`。conversation ごとの message。
- **Principal と AuthZ**: `/api/v2/principals`、`/api/v2/principal-groups`、`/api/v2/permission-grants`。[Principal と AuthZ](../principal-authz/) ページの permission model に対応します。

## ここに含まれないものについて

`/webhooks/*` は provider を認証します。runtime `/api/v1/ai-gateway/*` は AIGateway 認証を使用し、Console configuration route は本ページの session と CSRF 検査を使用します。

## 次のステップ

- Console が構成する runtime surface については、[AIGateway API](../ai-gateway/)、[Signals](../signals/)、[Sessions](../sessions/) をお読みください。
- Console 自身が従う permission model については、[Principal と AuthZ](../principal-authz/) をお読みください。
- 新しい deployment instance を構成するには、[クイックスタートの deployment セクション](../quickstart/#deployment) をお読みください。
