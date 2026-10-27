---
title: Console API リファレンス
description: Console が使用する /api/v2 API のリファレンス。認証方式、主要リソースのルート一覧、および認可の仕組みを説明します。
section: Reference
order: 203
---

Console API はマルチアカウント対応のブラウザーセッション認証を使用します。`Cookie` ヘッダーで暗号化・署名済みのセッション Cookie を送信し、`x-ankole-authentication` ヘッダーで操作対象のアカウントを指定します。サーバー側では `RequireSiteAdminSession` が有効な管理者セッションを解決し、対象 Human のアクセス状態を確認したうえで `Ankole.AuthZ` の actor（`console_rest`）をバインドし、`Ankole.AuthZ.Authorizer` が各 Ash アクションを `site_console:**` および `tenant_console:**` 権限で認可します。認証に失敗した場合は `401` が返ります。また、`GET` と `HEAD` 以外のリクエストにはシェルから取得した `x-csrf-token` ヘッダーが必須であり、CSRF トークンの欠落・不一致や権限不足の場合は `403` が返ります。

Console の設定変更、集約ビューの取得、および監査対象のシークレット操作はすべて `/api/v2` 配下に集約されています。サイト全体の管理ルートは `/api/v2/site` 配下に置かれ、テナント単位のルートは選択されたデータテナントに対して実行されます。以下の各表では、それぞれのルートの完全パスを記載しています。

`/api/v2` のリクエストとレスポンスには `application/vnd.api+json` を使用し、詳細な型定義は各操作の OpenAPI スキーマで規定されています。通常の作成・更新では `data.type` と `data.attributes` を使用しますが、generic アクションでは引数を `data` 直下に置き、JSON:API リソースドキュメントではなく型付きオブジェクトを返す場合があります（たとえば `PUT /api/v2/worker-envs/EXAMPLE` は `{"data":{"value":"example","secret":false}}` を受け取り、`worker_env` オブジェクトを返します）。一覧取得ルートでスキーマにキーセットページネーションが宣言されている場合は、`page[limit]` と `page[after]` を使用します。

テナント単位のルートでは、`x-ankole-tenant: <tenant UUID>` ヘッダーで操作対象のデータテナントを指定します（省略時は呼び出し元アカウントの所属テナントが使われます）。指定されたテナントが無効・利用不可・削除中のいずれかである場合は、`data_tenant_unavailable` とともに `404` が返ります。なお、このヘッダーによって呼び出し元自身の Identity やサイト管理権限が変わることはなく、`/api/v2/site` ルートのスコープにも影響しません。

Console 操作およびサイト管理操作の OpenAPI 3.1 ドキュメントは `/api/v2/openapi.json` と `/api/v2/site/openapi.json` で公開されており、閲覧には対象ルートと同じ認証が必要です。これ以外のブラウザー向け JSON:API スコープでも、`/api/v2/pod/openapi.json`（Pod ワークスペースおよび `pod_admin` 向けの `/api/v2/pod/admin/*` ルート）と `/api/v2/browser/openapi.json`（ブラウザー認証および初期セットアップ）がそれぞれ公開されています。ファイルのアップロードとダウンロードには後述する `/api/v2` のネイティブルートを使用し、ランタイムの AI 呼び出し・OIDC プロトコル・Webhook にはそれぞれ専用の API 契約を使用します。

## configuration の surface

API ルートは内部コントローラーの都合ではなく、「運用者が何を構成するか」という対象ごとに整理されています。主な設定用エンドポイントは次のとおりです。

### Provider と model アクセス

Agent を稼働させるには背後のモデル接続が不可欠です。運用者は AIGateway の provider 管理ルートと Agent のモデルプロファイルを通じてこれらを紐付けます。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/ai-gateway/provider-kinds` | このデプロイインスタンスで利用可能な provider kind を一覧取得 |
| `GET` | `/api/v2/site/ai-gateway/models` | Console の設定画面向けに capability 付きの provider モデル一覧を取得 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 設定済みの provider を一覧取得 |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 特定の provider とその credential pool の状態を取得 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | provider を作成または置換 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | provider を削除 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials` | credential pool にメンバーを追加 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | プールメンバーの設定更新または再認証 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | プールメンバーを削除 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | プールのメンバー選択戦略を設定 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT のデバイスログインまたはブラウザーログインを開始 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | デバイスログインの完了状態を 1 回ポーリング |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | ブラウザーコールバック URL 貼り付けによる代替ログインを完了 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Enterprise アクセストークンを追加 |
| `GET` | `/api/v2/agents/:agent_uid/model-profiles` | Agent のモデルプロファイル一覧を取得 |
| `PUT` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | モデルプロファイルを作成または置換 |
| `DELETE` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | モデルプロファイルを削除 |

Provider の認証情報は暗号化されたプールメンバーとして control plane 内にのみ保管され、Agent の実行環境へ渡されることはありません。モデルプロファイルは Agent を特定の provider とモデルに紐付け、AIGateway がその provider 内の正常なメンバーを選択します。API のレスポンスには安全なアカウント識別情報、ヘルス状態、レート制限情報、使用量だけが含まれます。

### Agent とその能力

Agent は、運用者が各種設定を組み立てる際の中心となる単位です。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/agents` | Agent を一覧取得 |
| `POST` | `/api/v2/agents` | Agent を新規作成 |
| `GET` | `/api/v2/agents/:agent_uid` | 特定の Agent の詳細を取得 |
| `PATCH` | `/api/v2/agents/:agent_uid` | Agent の設定を更新 |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 無効化されている Agent を再有効化 |
| `DELETE` | `/api/v2/agents/:agent_uid` | 有効な Agent なら無効化し、すでに無効化済みの Agent なら完全に削除 |

### Worker provider

各 Agent は作成時に使用する Worker provider を選択し、作成後は変更できません。Provider の YAML 構成と暗号化された認証情報は分けて保存されます。ライフサイクルと永続ストレージの仕様については、[Worker 管理](../worker-management/)を参照してください。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/worker-provider-kinds` | 利用可能な provider kind、YAML サンプル、必要な認証情報項目を一覧取得 |
| `GET` | `/api/v2/site/worker-providers` | 設定済みの Worker provider を一覧取得 |
| `POST` | `/api/v2/site/worker-providers` | Worker provider を新規作成 |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 設定または認証情報を更新 |
| `GET` | `/api/v2/site/worker-providers/:provider_id/check` | 接続性と権限をテスト |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | どの Agent からも使われていない provider を削除 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 移行後などで provider 未設定状態の Agent に provider を割り当て |

### signal routing rule

signal routing rule（API スキーマ上の名称は `Signal Binding`）は、外部チャネルなどの provider アダプターを Agent へ接続し、メッセージやイベントが Agent に届くようにします。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/signal-adapters` | このデプロイインスタンスで利用可能な signal アダプターを一覧取得 |
| `GET` | `/api/v2/signal-bindings` | ルーティングルールを一覧取得（`?agent=` で対象 Agent を絞り込み可能） |
| `PUT` | `/api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | ルーティングルールを作成または置換 |
| `PATCH` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | ルーティングルールを更新 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | ルーティングルールを無効化 |
| `GET` | `/api/v2/conversations/:conversation_id/standing-orders` | 特定の Conversation の standing orders を取得 |
| `PUT` | `/api/v2/conversations/:conversation_id/standing-orders` | 特定の Conversation の standing orders を更新 |

binding を無効化すると、設定レコード自体を残したまま、新着 Signal による Agent の起動だけを止められます。

### Agent Library の能力

Agent Library の既定値は選択中のテナントに属し、Agent ごとの上書き設定もそのテナント内で適用されます。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/agent-library/capabilities` | テナントのライブラリ機能一覧を取得 |
| `PUT` | `/api/v2/agent-library/agent-plugins/:id` | Agent Plugin のテナント既定状態を設定 |
| `PUT` | `/api/v2/agent-library/skills/:id` | Skill のテナント既定状態を設定 |
| `GET` | `/api/v2/agents/:agent_uid/library-capabilities` | 対象 Agent の実効能力一覧を取得 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 特定の Agent に対して Plugin 設定を上書き |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/skills/:id` | 特定の Agent に対して Skill 設定を上書き |
| `GET` | `/api/v2/agents/:agent_uid/library-documents` | Agent の永続ドキュメント一覧を取得 |
| `PUT` | `/api/v2/agents/:agent_uid/library-documents/:document_kind` | 指定した永続ドキュメントを更新 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 有効な Skill 教訓および廃止済み教訓を一覧取得 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 有効な Skill に人間由来の教訓を追加 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 教訓を廃止 |

まずテナント単位で既定の有効セットを決め、必要に応じて Agent ごとに許可範囲を絞ったり広げたりできます。Skill 教訓を使うと、元の `SKILL.md` を書き換えずに特定の Agent へ追加の作業指針を渡せます。一覧レスポンスには根拠や廃止履歴も含まれ、廃止された教訓は実行時に配信されなくなるほか、人間が却下・廃止した内容は Dreaming の再学習禁止リストに保持されます。ライフサイクルと制限の詳細については、[Skill 教訓](../skill-lessons/)を参照してください。

### 環境変数（WorkerEnv）

`WorkerEnv` はサイト既定値、テナント上書き値、および Agent 個別の割り当て値の 3 階層を持ちます。通常の一覧・更新ルートが返すのはメタデータのみであり、暗号化された平文値の取得は監査証跡が残る専用の `decryptions` ルートで行います。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/worker-envs` | サイト既定の環境変数一覧を取得 |
| `PUT` | `/api/v2/site/worker-envs/:name` | サイト既定値を設定 |
| `DELETE` | `/api/v2/site/worker-envs/:name` | サイト既定値を削除 |
| `POST` | `/api/v2/site/worker-envs/:name/decryptions` | サイト設定値を復号して取得 |
| `GET` | `/api/v2/worker-envs` | テナントの環境変数一覧を取得 |
| `PUT` | `/api/v2/worker-envs/:name` | テナント値を設定 |
| `DELETE` | `/api/v2/worker-envs/:name` | テナント値を削除 |
| `POST` | `/api/v2/worker-envs/:name/decryptions` | テナント設定値を復号して取得 |
| `GET` | `/api/v2/agents/:agent_uid/worker-envs` | Agent の環境変数割り当て一覧を取得 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Agent 個別の値を設定・上書き |
| `DELETE` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Agent 個別の割り当てを削除 |
| `POST` | `/api/v2/agents/:agent_uid/worker-envs/:name/decryptions` | Agent 個別の値を復号して取得 |

Agent の実行時には「Agent 個別値 → テナント値 → サイト既定値」の優先順で環境変数が解決されます。解決は Worker 上で新しい作業が始まるタイミングで行われ、すでに開いている既存の workspace は作成時点の環境変数を維持します。

### Control Plane Plugin

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | Control Plane Plugin の一覧と現在の状態を取得 |
| `PUT` | `/api/v2/site/control-plane-plugins` | プラグインの有効／無効を切り替え |

Control Plane Plugin はコンパイル時に組み込まれるファーストパーティ拡張であり、Signals アダプター、Identity Provider アダプター、AI Gateway provider、Worker provider などの機能を control plane に追加します。`activation: :always` のプラグインはビルドに含まれ常時有効となります。`PUT /api/v2/site/control-plane-plugins` では次回起動時に有効にする `:optional` プラグインを切り替えますが、その際、使用中の Worker provider など有効なリソースを抱えているプラグインが誤って無効化されないよう、各サブシステムの `veto_disable` チェックが実行されます。

### Identity provider と AppConfiguration

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/identity-provider-adapters` | このデプロイインスタンスが対応する IdP アダプターを一覧取得 |
| `GET` | `/api/v2/identity-providers` | 設定済みの Identity Provider を一覧取得 |
| `PUT` | `/api/v2/identity-providers/:provider_id` | IdP を作成または置換 |
| `POST` | `/api/v2/identity-providers/:provider_id/sync-runs` | IdP からディレクトリおよびグループを同期 |
| `GET` | `/api/v2/site/app-configurations` | サイトスコープの設定キー一覧を取得 |
| `PUT` | `/api/v2/site/app-configurations/:key` | サイトスコープの設定値を更新 |
| `POST` | `/api/v2/site/app-configurations/:key/decryptions` | サイトスコープの暗号化設定値を復号 |
| `GET` | `/api/v2/app-configurations` | テナントスコープの設定キー一覧を取得 |
| `PUT` | `/api/v2/app-configurations/:key` | テナントスコープの設定値を更新 |
| `POST` | `/api/v2/app-configurations/:key/decryptions` | テナントスコープの暗号化設定値を復号 |

`AppConfiguration` は宣言済みの運用パラメータをサイト単位またはテナント単位で保持します。サイトキーは `/api/v2/site/app-configurations` で、テナントキーは `/api/v2/app-configurations` で管理し、いずれも一覧取得・単一キー取得・値の設定・上書きのリセット・監査付きの復号に対応しています。なお、PostgreSQL 接続前のブートストラップに必要な認証情報や初期設定は、環境変数またはシークレットマウントで渡します。

### Tenant 管理

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | テナントを一覧取得 |
| `POST` | `/api/v2/site/tenants` | テナントを新規作成 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | テナント情報を更新 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | テナントの削除を要求 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | テナントを一時停止 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | テナントの一時停止を解除 |
| `GET` | `/api/v2/site/privileged-tenant` | 特権テナントの情報を取得 |
| `PATCH` | `/api/v2/site/privileged-tenant` | サイト管理権限を持つ特権テナントを別テナントへ移管 |

## 読み取り用の surface

Console API は設定変更だけでなく、システム全体の稼働状況を把握する観測（observability）経路としても機能します。各サブシステムの状態は次のルートから参照できます。

- **稼働中の Agent セッションとスケジュール**: `/api/v2/agents/:agent_uid/sessions`、および Agent ごとの cron スケジュール・checkback 管理ルート（テナント横断の一覧エンドポイントでは `agent` クエリパラメータで絞り込み可能）。
- **Worker の状態**: `/api/v2/agent-workers` から各 Agent の Worker 状態を一覧取得できます。
- **Agent ドライブ**: `/api/v2/agents/:agent_uid/files` でファイルの一覧取得・削除、`/api/v2/agents/:agent_uid/file-moves` で移動を行います。バイナリ転送にはネイティブルートを使い、`POST /api/v2/agents/:agent_uid/files` がマルチパートアップロード、`GET /api/v2/agents/:agent_uid/files/content` がダウンロードに対応します。ネイティブ転送ルートでも同じブラウザーセッション、CSRF 検証、テナント選択、ファイル権限チェックが適用され、ファイル自体の管理は control plane が担います。
- **Background Agent Job**: `/api/v2/background-agent-jobs`（一覧取得、詳細取得、キャンセル）。
- **AI 呼び出し履歴**: `/api/v2/ai-gateway/conversations`（会話ごとのモデル入出力メッセージ）。
- **Principal、AuthZ、OIDC クライアント**: `/api/v2/principals`（`PATCH /api/v2/principals/:uid/membership`、`POST /api/v2/principals/:uid/access-disables`、`POST /api/v2/principals/:uid/access-restorations` を含む）、`/api/v2/principal-groups`、`/api/v2/permission-grants`、および `/api/v2/oidc-clients`。これらは [Principal と AuthZ](../principal-authz/) で解説している権限モデルに対応しています。

## ここに含まれないものについて

外部連携用の `/webhooks/*` では送信元プロバイダーの署名・トークン検証を行い、ランタイム AI 呼び出し用の `/api/v1/ai-gateway/*` では AIGateway トークン認証を使用します。このページで説明したブラウザーセッションおよび CSRF 検査が使われるのは、Console 向けの `/api/v2` ルートです。

## 次のステップ

- Console から設定する各ランタイム境界の詳細については、[AIGateway API](../ai-gateway/)、[Signals](../signals/)、[Sessions](../sessions/) を参照してください。
- Console API 自身の認可を支える権限モデルについては、[Principal と AuthZ](../principal-authz/) を参照してください。
- 新しいデプロイインスタンスの立ち上げ手順については、[クイックスタートの deployment セクション](../quickstart/#deployment) を参照してください。
