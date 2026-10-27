---
title: AppConfigure
description: Console で Ankole の実行時設定（AppConfigure）を管理する方法と、組み込み設定キーの一覧を説明します。
section: User guide
order: 43
---

**Console → AppConfigure** では、デプロイインスタンスを稼働させたまま管理者が変更できる実行時設定を管理できます。たとえば、会話履歴の自動圧縮、Agent の同時実行上限、組織ディレクトリの同期間隔、プラグインの有効／無効切り替えなどが含まれます。

なお、LLM Provider、Identity Provider、チャットチャネル、環境変数にはそれぞれ専用の Console ページが用意されているため、AppConfigure 側で重複して設定する必要はありません。

## AppConfigure と環境変数

AppConfigure の設定値は PostgreSQL に保存され、稼働中の Ankole の製品動作を制御します。ほとんどの設定変更は保存後に始まる処理から即座に反映されるため、再デプロイは不要です。

一方、[デプロイ環境変数](../environment-variables/)は control plane や PostgreSQL の起動パラメータ、および Worker バックエンドの初期構成に使われます。これらを変更した場合は、対象プロセスの再起動が必要です。

Skill、コマンドラインツール、または MCP サービスに API キーなどのカスタム値を渡したい場合は、[Agent 環境変数](../worker-env/)を使用してください。

## 設定の探し方

AppConfigure ページでは、関連する設定項目がカテゴリごとにグループ化されています。キー名や説明文で検索できるほか、各グループを展開して一覧で確認することもできます。

各設定行は、次のいずれかの状態を持ちます。

- **編集可能:** 行を開いて、その場で値を変更できます。
- **読み取り専用:** 現在の値を確認できますが、この画面からは変更できません。
- **別の場所で管理:** 表示されている管理リンクから、その設定を担当する専用の Console ページへ移動できます。

設定キーは不変の識別子であり、説明欄にはそのキーが何を制御するか、また数値にどの単位（秒、ミリ秒、行数など）を使うかが記載されています。

## 適用範囲と値の出所を理解する

各設定キーには **Site** または **Tenant** のスコープがあります。Site キーはサイト全体の共有インフラを制御し、Tenant キーは選択中のテナントの動作を制御します。Console 上ではサイト既定値とテナントごとの上書き値（override）が区別して表示されます（Agent 単位の上書きはサポートしていません）。

Site キーでは「保存済みの値 → バージョンの既定値」の優先順で値が使われます。Tenant キーでは「テナントの上書き値 → 同一キーのサイト既定値 → バージョンの既定値」の順で解決されます。**Reset to default** を実行すると、選択中のスコープに保存された上書き値が削除されます。現在有効になっている値がどこから来ているかは、一覧の Source 列で確認できます。

## 設定の変更

1. 目的の設定項目または設定グループを開きます。
2. フィールドの説明を読み、適用スコープと数値の単位を確認します。
3. 必要な値を入力して保存します。
4. 一覧画面に戻り、該当行に上書き状態が反映されていることを確認します。

よく使われる設定には専用の入力フォームが用意されており、一部の高度な設定では JSON エディタを使用します。JSON を編集する際は既存のフィールド構造を保ち、用途がわからないフィールドを不用意に削除しないでください。

ほとんどの変更は後続の作業から自動的に適用されます。画面上に「次回起動時に反映される」旨の案内が表示されている項目については、都合のよいタイミングで control plane を再起動してください。

## 設定のリセット

カスタム値が不要になったら、対象の設定を開いて **Reset to default** を選択します。これにより保存済みの上書き値が削除され、現在インストールされているバージョンで定義された既定値に戻るようになります。

このリセット操作は、「現在の既定値と同じ数値を手動で入力して保存する」こととは意味が異なります。リセットしておけば将来のバージョンアップで既定値が変更された際に新しい既定値へ自動的に追従しますが、カスタム値として保存した場合は元の値が固定されたままになります。

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
| `agent_computer.background_agent_job.max_running_per_agent` | Tenant | 1 つの Agent あたり同時に実行できる BackgroundAgentJob の上限。既定値 `3`、有効範囲 `1`〜`64` |
| `automation_jobs.max_running_per_agent` | Tenant | 1 つの Agent あたり同時に実行できる自動化スクリプトの上限。既定値 `10`、有効範囲 `1`〜`64` |

### Pod、Base、Applet

| キー | 適用範囲 | 用途 |
|---|---|---|
| `pod.allow_external_guests` | Tenant | 招待された外部ゲストによる共有 Pod ページへのアクセスを許可するかどうか。既定値 `true` |
| `pod.applet.limits` | Tenant | Applet 呼び出しの制限値（既定値 `timeout_ms: 60000`、`heap_mb: 128`） |
| `pod.base.limits` | Tenant | Base のクエリおよびレコード制限値（既定値 `query_rows: 1000`、`record_bytes: 1000000`、`group_count: 1000`、`statement_timeout_ms: 5000`） |
| `pod.trash_retention_days` | Tenant | 削除されたページをゴミ箱から自動完全削除するまでの保持日数（正の整数、既定値 `30`）、または自動削除を行わない `"unlimited"` |
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
| `brain.forgetting` | Tenant | 知識種別ごとの減衰半減期および論理削除（soft-delete）データの完全消去間隔 |
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
| `authn.email.send_window_seconds` | Site | Email OTP コード送信のレート制限ウィンドウ秒数。既定値 `60` |
| `authn.email.send_email_limit` | Site | 送信ウィンドウ内で同一メールアドレス宛てに送信できる最大コード数。既定値 `3` |
| `authn.email.send_source_limit` | Site | 送信ウィンドウ内で同一送信元アドレスから要求できる最大コード数。既定値 `20` |
| `authn.email.send_channel_limit` | Site | 送信ウィンドウ内でチャネル全体に送信できる最大コード数。既定値 `100` |
| `authn.email.failure_window_seconds` | Site | コード検証失敗のレート制限ウィンドウ秒数。既定値 `600` |
| `authn.email.failure_email_limit` | Site | 失敗ウィンドウ内で同一メールアドレスに対して許容される最大検証失敗回数。既定値 `10` |
| `authn.email.failure_source_limit` | Site | 失敗ウィンドウ内で同一送信元アドレスに対して許容される最大検証失敗回数。既定値 `100` |
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
| `i18n.default_locale` | Tenant | Ankole インターフェースの既定表示言語 |

### Worker、web 読み取り、セキュリティ

| キー | 適用範囲 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Site、読み取り専用 | 初回起動時に control plane が生成するインストール識別キー。Lark プロファイルの命名などに使われ、Worker の認証情報としては使われない |
| `agent_computer.worker.ready_timeout` | Site | Worker が `ready` にならないまま待機を許容する秒数。超過すると新しいキャッシュディスクで再構築される。既定値は `600`（10 分） |
| `worker.rendered_fetch_idle_ttl_ms` | Tenant | 組み込み `web_fetch` のレンダリングフォールバック用ブラウザをアイドル保持する時間（ミリ秒） |
| `security.ssrf_filter` | Site | モデル主導の fetch リクエストに対して、プライベート IP、ループバック、リンクローカル、CGNAT アドレスへのアクセスを遮断するかどうか |

なお、`security.ssrf_filter` をオフにした場合でも、クラウドメタデータエンドポイントへのアクセスは常に遮断されます。

`agent_computer.worker.ready_timeout` は、起動後に準備完了へ進まないインスタンスを自動復旧するための設定です。アイドル状態のインスタンス解放については、provider YAML の `idleReleaseAfter` で設定します。詳しくは [Worker](../worker-management/) を参照してください。

### 初回セットアップの状態

| キー | 適用範囲 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | Site、読み取り専用 | 初回セットアップページで使用する一時アクティベーションコード |
| `setup.completed` | Site、読み取り専用 | このインスタンスで初回セットアップが完了済みかどうか |

これらのキーは初回セットアップフローによって管理されます。アクティベーションコードを確認したい場合は `kit show bootstrap-activation-code` を実行してください。AppConfigure ページから直接編集することはできません。

## 暗号化設定

認証情報にあたる設定項目は暗号化して保存され、一覧画面やエディタ上ではマスク表示されます。マスク表示のまま保存すれば現在の値が維持され、新しい値を入力して保存した場合のみ上書きされます。

現在の設定値を確認する必要がある場合に限り、**Reveal** を使用してください。表示された認証情報をチャット、スクリーンショット、チケットなどに貼り付けないよう注意してください。
