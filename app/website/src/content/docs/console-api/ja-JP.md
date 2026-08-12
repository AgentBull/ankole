---
title: Console API リファレンス
description: Console が使用する /api/v1 REST API のリファレンス。認証、リソースの route、authorization action を含みます。
section: Reference
order: 203
---

このページは Console API の REST リファレンスです。認証 gate、`/api/v1` 配下の route、各 route が実行する permission action を解説します。

最も重要な性質を先に述べます。Console API は stateless で bearer 認証を用い、すべての request で呼び出し元が依然として active な管理者であることを再確認します。この仕事を引き受ける session cookie はなく、無効化された管理者は次回のログイン時ではなく即座に機能しなくなります。

`/api/v1` 配下のすべての route は `:console_api` pipeline と `RequireConsoleAccessToken` plug を通ります。plug は次に挙げる 3 つの検査を、すべて必須として独立に実行します。

1. 形式が正しい `Authorization: Bearer` ヘッダ。
2. 検証に通る console JWT。
3. JWT が指す Principal が依然として active な管理者であること。

成功時は Principal と claims を conn assigns に保存して、後続の policy 検査に渡します。いずれかの検査が失敗すると `401` で停止します。これは、session と CSRF がブラウザ向け surface に対して行うことを、request 単位・cookie なしで実現したものです。これらの route へのより弱い第二の経路は存在しません。

## configuration の surface

configuration は controller 単位ではなく、「何を構成するか」で整理されています。運用者が実際に操作する surface は次のとおりです。

### Provider と model アクセス

稼働中の agent には背後に model が必要です。運用者は AIGateway の provider surface と agent の model profile を通じてそれを接続します。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/ai-gateway/provider-kinds` | この deployment instance が構成できる provider kind を一覧表示 |
| `GET` | `/ai-gateway/providers` | 構成済みの provider を一覧表示 |
| `GET` | `/ai-gateway/providers/:provider_id` | 1 つの provider とその credential pool の状態を読み取る |
| `PUT` | `/ai-gateway/providers/:provider_id` | provider を作成または置換 |
| `DELETE` | `/ai-gateway/providers/:provider_id` | provider を削除 |
| `POST` | `/ai-gateway/providers/:provider_id/credentials` | credential pool のメンバーを追加 |
| `PUT` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | pool メンバーを更新または再認証 |
| `DELETE` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | pool メンバーを削除 |
| `PUT` | `/ai-gateway/providers/:provider_id/credential-pool/strategy` | pool の選択 strategy を設定 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT の device または browser ログインを 1 回開始 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/poll` | device ログインを 1 回 poll |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | ブラウザ貼り付けの代替経路を完了 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Enterprise access token を追加 |
| `GET` | `/agents/:agent_uid/model-profiles` | agent の model profile を一覧表示 |
| `PUT` | `/agents/:agent_uid/model-profiles/:profile` | profile を作成または置換 |
| `DELETE` | `/agents/:agent_uid/model-profiles/:profile` | profile を削除 |

Provider の credential は暗号化された pool メンバーとして control plane に置かれ、agent の環境には決して置かれません。model profile は agent を provider と model に bind します。AIGateway はその provider 内で健全なメンバーを選択し、projection は安全な account 情報、健康状態、rate limit データ、使用量だけを返します。

### Agent とその能力

agent は、運用者が他のすべてを構成する際の単位です。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/agents` | agent を一覧表示 |
| `POST` | `/agents` | agent を作成 |
| `GET` | `/agents/:agent_uid` | 1 つの agent を読み取る |
| `PATCH` | `/agents/:agent_uid` | agent を更新 |
| `DELETE` | `/agents/:agent_uid` | agent を削除 |

### signal routing rule

signal routing rule（API schema では `Signal Binding`）は provider adapter を Agent に接続し、共有された仕事が Agent に届くようにします。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/signal-adapters` | この deployment instance が宣言した adapter を一覧表示 |
| `GET` | `/agents/:agent_uid/signal-bindings` | Agent の routing rule を一覧表示 |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | routing rule を作成または置換 |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | routing rule を更新 |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | routing rule を削除 |
| `GET` | `/signal-channels/:channel_id/standing-orders` | 1 つの channel の standing orders を読み取る |
| `PUT` | `/signal-channels/:channel_id/standing-orders` | 1 つの channel の standing orders を置換 |

binding を無効にすると、binding を削除せずに、新しい signal が agent を wake しなくなります。

### Agent Library の能力

Agent Library は agent ができること、つまり plugin と skill です。Console は 2 つの scope を公開します。1 つはグローバルな既定値、もう 1 つは agent 単位の override です。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | グローバルな library 能力を一覧表示 |
| `PUT` | `/agent-library/agent-plugins/:id` | plugin のグローバルな既定状態を設定 |
| `PUT` | `/agent-library/skills/:id` | skill のグローバルな既定状態を設定 |
| `GET` | `/agents/:agent_uid/library-capabilities` | agent の実効能力を一覧表示 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 1 つの agent に対して plugin を override |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 1 つの agent に対して skill を override |
| `GET` | `/agents/:agent_uid/library-documents` | agent の library document を一覧表示 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | library document を設定 |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | skill overlay を一覧表示 |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | skill overlay を設定 |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | skill overlay を削除 |

能力はまずグローバルに有効化され、その後 agent ごとに狭めたり広げたりできます。skill overlay を使うと、運用者は skill を fork せずに、1 つの agent に対する skill の振る舞いをカスタマイズできます。

### 環境変数（WorkerEnv）

Agent Computer Worker は、API key や token などの環境変数を必要とすることがあります。Console はこの機能を **環境変数** と呼びます。API はリソース名として `WorkerEnv` を保持します。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/worker-envs` | 名前付きの WorkerEnv エントリを一覧表示 |
| `GET` | `/worker-envs/:name` | 1 つのエントリを読み取る（metadata。plaintext ではない） |
| `PUT` | `/worker-envs/:name` | エントリを作成または更新 |
| `DELETE` | `/worker-envs/:name` | エントリを削除 |
| `GET` | `/agents/:agent_uid/worker-envs` | agent に付与されたエントリを一覧表示 |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | agent にエントリを付与 |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | エントリを剥奪 |
| `POST` | `/worker-envs/:name/decryptions` | 1 つのエントリを復号（audit 対象、特権操作） |

復号は独立した audit 対象の操作です。一覧表示と読み取りは metadata を返し、secret の値は返しません。worker が環境を受け取るのは turn の開始時だけです。変更は次の turn で反映され、実行中の turn には反映されません。

### Control Plane Plugin

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/control-plane-plugins` | Control Plane Plugin とその状態を一覧表示 |
| `PUT` | `/control-plane-plugins` | plugin を有効化または無効化 |

Control Plane Plugin は、signals adapter や Brain の source connector のように、control plane 自身の動作を変えるファーストパーティ拡張です。

### Identity provider と AppConfiguration

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/identity-provider-adapters` | この deployment instance がサポートする IdP adapter を一覧表示 |
| `GET` | `/identity-providers` | 構成済みの identity provider を一覧表示 |
| `PUT` | `/identity-providers/:provider_id` | IdP を作成または置換 |
| `POST` | `/identity-providers/:provider_id/sync-runs` | IdP から directory group を同期 |
| `GET` | `/app-configurations` | 運用者が管理する configuration key を一覧表示 |
| `PUT` | `/app-configurations/:key` | configuration の値を設定 |
| `POST` | `/app-configurations/:key/decryptions` | 1 つの secret configuration 値を復号 |

`AppConfiguration` は運用者が管理する設定、つまり宣言済みの `Ankole.AppConfigure` key のためのものです。bootstrap configuration（process 起動時の事実と credential）は、プロジェクトの境界の要求どおり、環境変数または secret mount に置かれ、ここからは除外されます。

## 読み取り用の surface

configuration に加えて、Console はシステムの残りの部分に対する observability の経路でもあります。既に解説した各 subsystem は、ここに読み取り用の surface を持ちます。

- **処理中の Agent**: `/agents/:agent_uid/sessions`。Agent ごとの cron schedule と checkback。
- **Worker**: `/agent-computer-workers`。worker ごとの file のアップロード、移動、一覧表示。
- **Job**: `/background-agent-jobs`（一覧表示、読み取り、cancel）。
- **AI の活動**: `/ai-gateway/conversations`。conversation ごとの message。
- **Memory**: `/brain/*` の全 surface。エントリ、source、audit log、dreaming の実行と fitness、restoration。
- **Principal と AuthZ**: `/principals`、`/principal-groups`、`/permission-grants`。[Principal と AuthZ](../principal-authz/) ページの permission model に対応します。

## ここに含まれないものについて

`/webhooks/*` と `/api/v1/ai-gateway/*` の route は、意図的に `console_api` の下にありません。webhook の入口は管理者ではなく provider を認証します。AIGateway の runtime API は、ライブな AI 呼び出しのために agent または admin token を検証します。Console は運用者の configuration surface であり、deployment instance の動作を変更するために admin の bearer token を信頼する唯一の surface です。

## 次のステップ

- Console が構成する runtime surface については、[AIGateway API](../ai-gateway/)、[SignalsGateway](../signals-gateway/)、[Actor Runtime](../actor-runtime/) をお読みください。
- Console 自身が従う permission model については、[Principal と AuthZ](../principal-authz/) をお読みください。
- 新しい deployment instance を構成するには、[クイックスタートの deployment セクション](../quickstart/#deployment) をお読みください。