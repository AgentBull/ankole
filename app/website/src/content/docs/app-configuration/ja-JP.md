---
title: AppConfigure
description: Console で Ankole の AppConfigure 実行時設定を管理し、組み込みの設定キーを参照します。
section: User guide
order: 43
---

**Console → AppConfigure** には、デプロイメント インスタンスの稼働中に管理者が変更できる設定が表示されます。例としては、会話履歴の圧縮、Agent の実行上限、企業 directory の同期間隔、plugin の有効/無効スイッチなどがあります。

LLM Provider、Identity Provider、chat channel、環境変数は、それぞれ専用の Console ページがあります。ここで再度設定する必要はありません。

## AppConfigure と環境変数

AppConfigure 設定は PostgreSQL に保存されます。これらはインスタンスの稼働中における Ankole の製品動作を制御します。ほとんどの変更は後続の作業に適用され、再デプロイは不要です。

[デプロイ環境変数](../environment-variables/) は control plane と PostgreSQL の起動、および Worker バックエンドの構成に使われます。変更後は該当するプロセスを再起動してください。

Skill、コマンドラインツール、MCP service が API key などのカスタム値を必要とする場合は、[Agent 環境変数](../worker-env/) を使用してください。

## 設定の探し方

このページでは関連する設定がグループ化されています。キー名または説明で検索できるほか、グループを開いてまとめて確認できます。

各行には次のいずれかの状態があります。

- **編集可能:** 行を開いて、ここで変更できます。
- **読み取り専用:** 行には現在の状態が表示されますが、ここでは変更できません。
- **別の場所で管理:** 管理リンクをたどって、設定を所有する Console ページを開きます。

キーは設定の安定した名前です。説明には、その設定が何を制御するかと、数値がどの単位を使うかが書かれています。

## 適用範囲と値の出所を理解する

設定キーは **Site** または **Tenant** scope を持ちます。Site key は共有インフラ、Tenant key は選択した tenant の動作を制御します。Console は site デフォルトと tenant の override を分けて表示します。Agent override はサポートしません。

Site key は保存済みの値、次にバージョンのデフォルトを使用します。Tenant key は tenant override、同じ key の site デフォルト、バージョンのデフォルトの順で解決します。**Reset to default** は選択した scope の override を削除します。Source 列は有効な値の出所を示します。

## 設定の変更

1. 設定または設定グループを開きます。
2. フィールドの説明を読み、適用範囲と単位を確認します。
3. 必要な値を変更して保存します。
4. 一覧に戻り、その行に上書きが表示されていることを確認します。

一般的な設定には専用のフォームがあります。一部の高度な設定は JSON エディタを使います。既存のフィールド構造は維持し、理解できないフィールドを削除しないでください。

ほとんどの変更は後続の作業に適用されます。ページに変更が次回起動時に適用されると書かれている場合は、都合のよい時間に control plane を再起動してください。

## 設定のリセット

カスタム値が不要になったら、設定を開いて **Reset to default** を選択します。保存された上書きが削除され、Ankole はインストールされているバージョンが宣言するデフォルト値を使うようになります。

リセットは、現在のデフォルト値をカスタム値として入力するのとは異なります。リセットすると、以降のバージョンでデフォルト値が変わった場合にそれに追従します。保存されたカスタム値は追従しません。

## 現在の組み込み AppConfigure キー

以下の AppConfigure キーは Ankole に組み込まれています。Control Plane Plugin がさらにキーを登録できます。現在のインスタンスの **AppConfigure** ページが権威ある一覧です。

### Agent runtime

| キー | 適用範囲 | 用途 |
|---|---|---|
| `ai_agent.max_iterations` | Tenant | 1 回の Agent turn で許可されるモデルの最大反復回数 |
| `ai_agent.max_output_tokens` | Tenant | 1 回のモデル応答に対する出力 token の上限 |
| `ai_agent.inactivity_timeout_ms` | Tenant | 非アクティブなモデルまたは Provider を、turn を終了するまで待つ時間 |
| `ai_agent.library.agent_plugin_defaults` | Tenant | Agent Plugin のデフォルトの有効状態 |
| `ai_agent.library.skill_defaults` | Tenant | Skill のデフォルトの有効状態 |

### Workflow

| キー | 適用範囲 | 用途 |
|---|---|---|
| `workflow.max_concurrency_per_run` | Tenant | 1 つの Workflow が要求できるタスク同時実行数の上限。デフォルト `8`、有効範囲 `1`〜`32` |
| `workflow.max_running_per_agent` | Tenant | 1 つの Agent の複数 run にまたがって実行できる Workflow タスク数の上限。デフォルト `8`、有効範囲 `1`〜`64` |
| `workflow.max_agent_calls_per_run` | Tenant | 1 つの Workflow が作成できるサブエージェント call 数の上限。デフォルト `32`、有効範囲 `1`〜`1,024` |

これらの上限は、後から開始する Workflow の作業に適用されます。run はより低い同時実行数または call 上限を要求できますが、tenant 上限は引き上げられません。タスクの動作と他のサイズ境界は [Workflow](../workflows/) を参照してください。

### Brain

| キー | 適用範囲 | 用途 |
|---|---|---|
| `brain.enabled` | Tenant | Brain の検索、学習、保守を有効にする。無効にしても保存済みの知識は残る |
| `brain.maintainer_agent_uid` | Tenant | Brain のメンテナンスを担当する有効な Agent。Brain のすべてのモデル呼び出しは、この Agent の ID で実行され、使用量もこの Agent に帰属する。無効にすると、再度有効にするか変更するまで、これらの呼び出しと URL Source 取得を停止する。Agent ページで `light`、`heavy`、`web_fetch` profile を編集する |
| `brain.embedding_model` | Site | ベクトル検索に使う Provider、モデル、次元数。空の場合はベクトル検索を無効にする |
| `brain.rerank_model` | Tenant | 検索結果の rerank に使う Provider とモデル。空の場合は融合後の順序を保つ |
| `brain.search_tokenizer` | Site | BM25 tokenizer: `icu`、`jieba`、`lindera_japanese`、`lindera_korean`。変更後は BM25 index の再構築が必要 |
| `brain.chunking` | Tenant | Source chunk のサイズ、overlap、入力上限 |
| `brain.forgetting` | Tenant | 知識の種類ごとの減衰半減期と soft-delete の purge 間隔 |
| `brain.dreaming_task_cron` | Tenant | 定期的に知識を統合する schedule |
| `brain.self_healing_task_cron` | Tenant | 古くなった chunk、embedding、search index の projection を再構築する schedule |
| `brain.signal_channel_batch_idle_time` | Tenant | 未処理の chat message が学習に入るまでの idle 秒数。会話の終了時にも学習を開始する |
| `brain.skill_learning_enabled` | Tenant | Skill lesson の学習と提供を有効にする。無効時は保存済みの lesson が残るが、提供されない |
| `brain.skill_learning_reflection_threshold` | Tenant | 1 つの Agent が Skill lesson の reflection を始めるまでに必要な未消費 Signal Job 数。最小値は `2` |

知識の動作とモデル要件については [Brain](../brain/) を参照してください。Skill と共に提供される lesson については [Skill lessons](../skill-lessons/) を参照してください。

### AI Gateway と observability

| キー | 適用範囲 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | Site | 会話履歴の自動圧縮ポリシー |
| `observability.traces.enabled` | Site | 次回の control-plane startup で process-wide OpenTelemetry export を有効にするかどうか |
| `observability.traces.provider` | Site | `langfuse`、`langsmith`、または汎用 `opentelemetry` trace の semantic projection |
| `observability.traces.otlp_endpoint` | Site | optional trace の base OTLP/HTTP endpoint |
| `observability.traces.otlp_headers` | Site | optional trace の暗号化された authentication header |

Langfuse、LangSmith、VictoriaTraces と他の OTLP/HTTP receiver の構成については [LLM observability](../llm-observability/) を参照してください。

### Identity、Plugin、tenant のデフォルト値

| キー | 適用範囲 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | Tenant、読み取り専用 | 管理者のサインインに使える Identity ソース。Identity Provider ページで管理 |
| `principals.identity_providers.directory_full_sync_interval_minutes` | Tenant | 組織 directory の全量同期間隔 |
| `plugins.enabled_ids` | Site | 次回起動時に有効にする Control Plane Plugin |
| `system.timezone` | Tenant | schedule など control plane 機能が使うデフォルトのタイムゾーン |
| `i18n.default_locale` | Tenant | Ankole インターフェースのデフォルト言語 |

### Worker、web 読み取り、セキュリティ

| キー | 適用範囲 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | Site、読み取り専用 | control plane が初回起動時に生成するインストールキー。Lark profile の命名に使い、Worker の credential ではない |
| `agent_computer.worker.ready_timeout` | Site | Worker が ready でないまま許容される秒数。超えると新しいキャッシュディスクで再構築される。既定は `600`（10 分） |
| `worker.rendered_fetch_idle_ttl_ms` | Tenant | 組み込みの `web_fetch` レンダリングフォールバックのアイドル保持時間 |
| `security.ssrf_filter` | Site | モデルが制御する fetch が private、loopback、link-local、CGNAT アドレスへのアクセスを拒否するかどうか |

この設定がオフであっても、クラウドメタデータのアドレスは拒否されます。

`agent_computer.worker.ready_timeout` は観測済みで未準備のインスタンスを復旧します。アイドル解放は provider YAML の `idleReleaseAfter` で設定します。[Worker](../worker-management/)を参照してください。

### 初回セットアップの状態

| キー | 適用範囲 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | Site、読み取り専用 | 初回セットアップページ用の一時アクティベーションコード |
| `setup.completed` | Site、読み取り専用 | このインスタンスが初回セットアップを完了したかどうか |

これらのキーは初回セットアップのフローが所有します。アクティベーションコードを確認するには、`kit show bootstrap-activation-code` を実行してください。このキーを AppConfigure ページで編集しないでください。

## 暗号化設定

Ankole は credential 設定を暗号化して保存し、一覧とエディタではマスクを表示します。マスクのまま保存すると現在の値が維持されます。新しい内容を入力すると置き換えられます。

現在の値を確認する必要がある場合にのみ、**Reveal** を使用してください。表示された credential を chat、スクリーンショット、ticket にコピーしないでください。
