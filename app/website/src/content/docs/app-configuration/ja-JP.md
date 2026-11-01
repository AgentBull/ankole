---
title: AppConfigure
description: Console で Ankole の実行時設定（AppConfigure）を管理する方法と、組み込み設定キーの一覧を説明します。
section: User guide
order: 43
---

サイト管理者は **Console → AppConfigure** でサイト既定値、ワークスペース方針、共有ランタイム設定を管理します。Pod 管理者は Pod 設定で許可された管理機能を使用します。

## 設定を探して範囲を選ぶ

編集前に**サイト設定と既定値**または**現在のワークスペースの上書き**を選びます。データのワークスペース名は常に表示されます。サイト既定値は上書きのないワークスペースに適用される値であり、強制的な上限ではありません。

既定のタスク表示では、関連設定を一つのフォームで編集し、有効状態・上書き・適用状況を確認できます。読み取り専用のキー一覧では、登録済みキーとパターンの範囲、値の出所、暗号化状態、管理画面を確認できます。検索はフォーム内のフィールドや旧キー名にも対応し、該当フィールドを開きます。管理リンクは担当する Console 画面とタブに移動します。

サイト設定は保存済みサイト値、コードの既定値の順に解決します。テナント設定は、実際に対応する Agent 上書き、ワークスペース上書き、サイト既定値、コードの既定値の順です。Pod 設定はワークスペース値とコードの既定値だけを使用します。対応する五つのキーでは Agent の適用値を読み取り専用で確認できます。

## 変更とリセット

一つの範囲で単位を確認して保存します。グループ設定は一括で確定し、一項目でも拒否されるとすべて変更せず、下書きを保持します。秘密情報は明示的に表示するまでマスクされます。リセット確認には現在値と、上書き解除後の実際の値・出所が表示されます。同じ値でも、保存した上書きは解除するまで独立した設定です。

時間は保存単位を変えずに読みやすい単位で入力できます。出力上限の指定なし（`null`）と数値上限を区別し、無応答タイムアウトは明示的に無効（`0`）にできます。削除データの保持期間を短くする場合は、完全削除の影響を表示します。

Trace と Control Plane Plugin の再起動待ち表示は、実行中プロセスと保存値が一致するまで残ります。Brain の Tick は共有 BM25 インデックスを毎分確認し、トークナイザーの変更時に再構築します。検索の中断や書き込み待ちが発生する場合があります。失敗時は Brain のヘルス画面とサーバーの Tick ログを確認してください。

SMTP は保存前の下書きでテスト送信でき、保存設定や OTP を変更しません。パスワードを入力しなければ保存済みの値を保持します。成功はメール転送サービスが受け付けたことを意味し、下書きを変えると結果は無効になります。SaaS の Turnstile は両方のキーを保持したまま無効にできます。

## 環境変数との違い

AppConfigure は製品設定を PostgreSQL に保存し、多くの変更は後続の処理に適用します。[デプロイ環境変数](../environment-variables/)は起動基盤を設定します。ツール用の認証情報は [Agent 環境変数](../worker-env/)で管理してください。

## 現在の組み込み AppConfigure キー

以下の AppConfigure キーは Ankole 本体に組み込まれているものです。これに加えて Control Plane Plugin が独自のキーを登録する場合もあるため、稼働中のインスタンスにおける正確な一覧は実際の **AppConfigure** ページで確認してください。

### Agent runtime

| キー | 適用範囲 | 用途 |
|---|---|---|
| `ai_agent.max_iterations` | Tenant | 1 回の Agent turn で許可されるモデルの最大反復回数 |
| `ai_agent.max_output_tokens` | Tenant | 1 回のモデル応答に対する出力トークンの上限 |
| `ai_agent.inactivity_timeout_ms` | Tenant | モデルまたは Provider からの応答が途絶えた際、turn を終了するまでの待機時間（ミリ秒） |
| `ai_agent.library.agent_plugin_defaults` | Tenant | Agent Plugin の既定の有効／無効状態 |
| `ai_agent.library.skill_defaults` | Tenant | Skill の既定の有効／無効状態 |
| `background_agent_jobs.max_running_per_agent` | Tenant | 1 つの Agent あたり同時に実行できる BackgroundAgentJob の上限。既定値 `3`、有効範囲 `1`〜`64` |
| `automation_jobs.max_running_per_agent` | Tenant | 1 つの Agent あたり同時に実行できる自動化スクリプトの上限。既定値 `10`、有効範囲 `1`〜`64` |

### Pod、Base、Applet

| キー | 適用範囲 | 用途 |
|---|---|---|
| `pod.allow_external_guests` | Tenant | 招待された外部ゲストによる共有 Pod ページへのアクセスを許可するかどうか。既定値 `true` |
| `pod.applet.limits` | Tenant | Applet 呼び出しの制限値（既定値 `timeout_ms: 60000`、`heap_mb: 128`） |
| `pod.base.limits` | Tenant | Base のクエリおよびレコード制限値（既定値 `query_rows: 1000`、`record_bytes: 1000000`、`group_count: 1000`、`statement_timeout_ms: 5000`） |
| `drive.trash_retention_days` | Tenant  削除された Drive ノードを自動で完全削除するまでの保持日数。既定値は `30`。`0` にすると無期限に保持 |
| `pod.ot_replay_window` | Tenant | OT リプレイ用に保持する直近のドキュメント変更バッチ数。既定値 `1000` |

### Workflow

| キー | 適用範囲 | 用途 |
|---|---|---|
| `workflow.max_concurrency_per_run` | Tenant | 1 つの Workflow が要求できるタスク同時実行数の上限。既定値 `8`、有効範囲 `1`〜`32` |
| `workflow.max_running_per_agent` | Tenant | 1 つの Agent で複数の run にまたがって同時実行できる Workflow タスク数の上限。既定値 `8`、有効範囲 `1`〜`64` |
| `workflow.max_agent_calls_per_run` | Tenant | 1 つの Workflow が作成できるサブエージェント呼び出し数の上限。既定値 `32`、有効範囲 `1`〜`1,024` |

これらの上限は、設定変更後に新しく開始される Workflow 作業に適用されます。個々の run でこれより低い同時実行数や呼び出し上限を指定することはできますが、テナント上限を超えて引き上げることはできません。タスクの挙動やその他のサイズ制限については、[Workflow](../workflows/) を参照してください。

### Brain

| キー | 適用範囲 | 用途 |
|---|---|---|
| `brain.enabled` | Tenant | Brain の検索・学習・保守処理を有効にする。無効化しても保存済みの知識は保持される |
| `brain.maintainer_agent_uid` | Tenant | Brain のメンテナンスを担当する有効な Agent。Brain によるすべてのモデル呼び出しはこの Agent の ID で実行され、使用量もこの Agent に帰属する。対象 Agent が無効になると、再有効化または別 Agent への変更を行うまでモデル呼び出しと URL Source の取得が停止する。モデルの変更は Agent ページで `light`、`heavy`、`web_fetch` プロファイルを編集して行う |
| `brain.embedding_model` | Site | ベクトル検索に使用する Provider、モデル、次元数。空欄の場合はベクトル検索が無効になる |
| `brain.rerank_model` | Tenant | 検索結果の rerank に使用する Provider とモデル。空欄の場合はスコア融合後の順序がそのまま使われる |
| `brain.search_tokenizer` | Site | BM25 トークナイザー（`icu`、`jieba`、`lindera_japanese`、`lindera_korean`）。変更後は BM25 インデックスの再構築が必要 |
| `brain.chunking` | Tenant | Source チャンクのサイズ、オーバーラップ、入力上限 |
| `brain.forgetting` | テナント | 記憶の種類ごとの減衰半減期 |
| `brain.soft_delete_retention_hours` | テナント | Dreaming がソフト削除したオブジェクトを完全削除するまでの保持時間。既定 `72` 時間 |
| `brain.dreaming_task_cron` | Tenant | 知識の統合処理（Dreaming）を定期実行するスケジュール |
| `brain.self_healing_task_cron` | Tenant | 古くなったチャンク、embedding、検索インデックスの投影を再構築するスケジュール |
| `brain.signal_channel_batch_idle_time` | Tenant | 未処理のチャットメッセージが学習処理へ送られるまでのアイドル秒数（会話終了時にも学習が開始される） |
| `brain.skill_learning_enabled` | Tenant | Skill lesson の学習と配信を有効にする。無効化しても保存済みの lesson は残るが、実行時には提供されなくなる |
| `brain.skill_learning_reflection_threshold` | Tenant | 1 つの Agent が Skill lesson の振り返り（reflection）を開始するまでに必要な未処理 Signal Job 数。最小値は `2` |

知識管理の仕組みと必要なモデル設定については [Brain](../brain/) を、Skill とあわせて提示される教訓については [Skill lessons](../skill-lessons/) を参照してください。

### AI Gateway と observability

| キー | 適用範囲 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | Site | 会話履歴の自動圧縮ポリシー |
| `observability.traces.enabled` | Site | 次回の control plane 起動時にプロセス全体の OpenTelemetry エクスポートを有効にするかどうか |
| `observability.traces.provider` | Site | トレースのセマンティック投影方式（`langfuse`、`langsmith`、または汎用の `opentelemetry`） |
| `observability.traces.otlp_endpoint` | Site | トレース送信先のベース OTLP/HTTP エンドポイント（任意） |
| `observability.traces.otlp_headers` | Site | トレース送信時に付与する暗号化済み認証ヘッダー（任意） |

Langfuse、LangSmith、VictoriaTraces およびその他の OTLP/HTTP レシーバーの設定手順については、[LLM observability](../llm-observability/) を参照してください。

### パスワードレス Email OTP と Pod ログインポリシー

| キー | 適用範囲 | 用途 |
|---|---|---|
| `authn.email.mail` | Site、暗号化 | パスワードレス Email OTP サインイン用の SMTP 配信設定（`server`、`from`、`port`、`ssl`、および任意の認証情報）。空の場合は Email OTP が無効になる |
| `authn.email.code_ttl_seconds` | Site | 認証コードの有効秒数。既定値 `600` |
| `authn.email.send_limits` | サイト | 共通の送信時間枠とメールアドレス・送信元・チャネルごとの上限 |
| `authn.email.failure_limits` | サイト | 共通の検証失敗時間枠とメールアドレス・送信元ごとの上限 |
| `principals.pod_login_policy` | Tenant、別の場所で管理 | Pod メンバーのログインおよび招待ポリシー（`allow_email_otp`、`allow_member_credential_change`、`allowed_email_domains`、`require_sso_for_members`、`allow_invite_links`）。Pod Settings で管理 |

### Identity、Plugin、機能フラグ、tenant のデフォルト値

| キー | 適用範囲 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | Tenant、読み取り専用 | Pod ワークスペースのメンバーと管理者の認証に使われる有効なテナント Identity Provider。Pod Settings および Identity Provider ページで管理 |
| `principals.identity_providers.directory_full_sync_interval_minutes` | Tenant | 組織ディレクトリのフル同期を実行する間隔（分） |
| `tenants.privileged_tenant_id` | Site、読み取り専用 | このサイトを管理する `siteadmin` グループを持つ特権テナントの ID |
| `plugins.enabled_ids` | Site、別の場所で管理 | 次回起動時に有効化する `:optional` な Control Plane Plugin の一覧（`:always` プラグインはビルドに含まれ常時有効） |
| `features.<flag>` | Site | OpenFeature ベースの機能公開ポリシー（`{enabled, percent, targets}`、`Ankole.Features.Config`） |
| `signals.show_dead_letter_error_details` | Site | Conversation に投稿される dead letter 通知に、文字数制限およびマスク処理済みの Session turn エラー詳細を含めるかどうか。既定値 `false` |
| `system.timezone` | Tenant | スケジュール実行など control plane 機能で使用する既定タイムゾーン |
| `i18n.default_locale` | Pod | この Pod ワークスペースのインターフェース、通知メール、Agent メッセージの既定表示言語（Pod 管理者は Pod Settings からも変更可能） |

### Worker、web 読み取り、セキュリティ

| キー | 適用範囲 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Site、読み取り専用 | 初回起動時に control plane が生成するインストール識別キー。Lark プロファイルの命名などに使われ、Worker の認証情報としては使われない |
| `agent_workers.ready_timeout_seconds` | Site | Worker が `ready` にならないまま待機を許容する秒数。超過すると新しいキャッシュディスクで再構築される。既定値は `600`（10 分） |
| `agent_workers.rendered_fetch_idle_ttl_ms` | Tenant | 組み込み `web_fetch` のレンダリングフォールバック用ブラウザをアイドル保持する時間（ミリ秒） |
| `security.ssrf_filter` | Site | モデル主導の fetch リクエストに対して、プライベート IP、ループバック、リンクローカル、CGNAT アドレスへのアクセスを遮断するかどうか |

なお、`security.ssrf_filter` をオフにした場合でも、クラウドメタデータエンドポイントへのアクセスは常に遮断されます。

`agent_workers.ready_timeout_seconds` は、起動後に準備完了へ進まないインスタンスを自動復旧するための設定です。アイドル状態のインスタンス解放については、provider YAML の `idleReleaseAfter` で設定します。詳しくは [Worker](../worker-management/) を参照してください。

### 初回セットアップの状態

| キー | 適用範囲 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | Site、読み取り専用 | 初回セットアップページで使用する一時アクティベーションコード |
| `setup.completed` | Site、読み取り専用 | このインスタンスで初回セットアップが完了済みかどうか |

これらのキーは初回セットアップフローによって管理されます。アクティベーションコードを確認したい場合は `kit show bootstrap-activation-code` を実行してください。AppConfigure ページから直接編集することはできません。

## 暗号化設定

認証情報にあたる設定項目は暗号化して保存され、一覧画面やエディタ上ではマスク表示されます。マスク表示のまま保存すれば現在の値が維持され、新しい値を入力して保存した場合のみ上書きされます。

現在の設定値を確認する必要がある場合に限り、**Reveal** を使用してください。表示された認証情報をチャット、スクリーンショット、チケットなどに貼り付けないよう注意してください。
