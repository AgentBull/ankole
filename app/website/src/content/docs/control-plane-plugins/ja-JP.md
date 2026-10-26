---
title: Control Plane Plugins
description: コントロールプレーンのファーストパーティ Elixir 拡張モデル — アクティベーションモード、サブシステム契約、トランザクションフック、Cohort 監督ツリー、次回起動時の有効化境界。
section: Developer guide
order: 110
---

Control Plane Plugins は、信頼されたファーストパーティの Elixir/OTP コードで Ankole サイトを拡張する仕組みです。プラグインは `Ankole.Plugins` を通じて `AppConfigure` キー、サブシステムアダプター、同期トランザクションフック、および監督付き子プロセスを追加できます。

Control Plane Plugins はリリースにコンパイルされるファーストパーティの Elixir モジュール（`:control_plane_plugin_modules`）であり、実行時に外部コードを読み込むマーケットプレイスやサンドボックス機構ではありません。起動時に発見・検証され、`:optional` プラグインはグローバル有効化リストを通じて次回プロセス起動時に有効化されます。一方、`activation: :always` を宣言したプラグインはビルドに含まれる限り常にアクティブになります。

## 発見済みとアクティブの 2 段階

プラグインには実行時に 2 つの状態があります。

- **発見済み（Discovered）** — リリースにコンパイルされ、起動時に検証されたすべてのプラグインモジュール。オペレーターは Site Admin Console で完全なカタログを確認できます。
- **アクティブ（Active）** — `activation/0` が `:always` のプラグイン、または `activation/0` が `:optional` で `plugins.enabled_ids` に含まれるプラグイン（初回セットアップ `setup.completed` 完了前はすべての発見済みプラグインがアクティブ）。アクティブなプラグインのみが `AppConfigure` 定義の登録、サブシステムアダプターやドメインフックの公開、監督付き子プロセスの起動を行います。

発見済みでも非アクティブなプラグインはカタログに表示され、保存済みの `AppConfigure` 設定値も PostgreSQL に保持されますが、定義・アダプター・フック・プロセスは実行時に一切登録されません。

## プラグイン契約

プラグインモジュールは `Ankole.Plugins.Plugin` ビヘイビアを実装します。必須コールバックは 1 つだけです。

- **`plugin_id/0`** — `~r/\A[a-z][a-z0-9_-]*\z/` に一致する一意な小文字スラッグ。

その他のコールバックはすべて任意です。

- **`activation/0`** — `:optional | :always` を返します（デフォルトは `:optional`）。`:optional` は `plugins.enabled_ids` に従い、`:always` はソースビルドに含まれる限り常時アクティブとなり無効化要求を拒否します。
- **`display_name/0`**、**`description/0`** — 管理画面向けのローカライズ済みテキストマップ。
- **`app_config_definitions/0`**、**`app_config_patterns/0`** — プラグインが提供する `Ankole.AppConfigure` キーおよびパターン定義。
- **`adapter_declarations/0`** — プラグインをサブシステム契約に接続するアトムキー付き宣言リスト。ブラウザフォーム用のスキーマには `Ankole.Plugins.ConfigField` を使用します。
- **`hooks/0`** — 同期トランザクションフック `[{hook_point, module}]`。各モジュールは宣言されたフックポイント（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）で `Ankole.Plugins.Hook.before_commit_in_tx/2` を実装し、`{:error, reason}` を返すことで呼び出し元のデータベーストランザクションをロールバックできます。
- **`children/0`** — プラグインランタイムスーパーバイザー配下で起動する `Supervisor.child_spec()` のリスト。

`Ankole.Plugins.Spec.from_module/1` は起動時にこれらを読み取って検証済みの `Spec` を構築します。形状検証エラー、ID 重複、または契約検証エラーがある場合、問題のモジュールを明示してアプリケーション起動を停止します。

## サブシステム契約とサイト拡張ポイント

`Ankole.Plugins.Contracts` は 5 つのサブシステムアダプター契約を定義しており、各契約は起動時の `validate` に加え、必要に応じて `refresh` 公開と `veto_disable` ガードを提供します。

- **`signals.adapter`** — `Ankole.Signals.Adapters` が検証するメッセージング・イベントアダプターを宣言し、Signal Bindings と Conversations 配信で利用可能にします。
- **`signals.webhook_handler`** — `/webhooks/v1/:handler_id/:instance_id/:kind` 用の HTTP Webhook ハンドラーを宣言します（`Ankole.Signals.WebhookHandlers` が検証）。
- **`principals.identity_provider`** — エンタープライズ Identity Provider およびディレクトリ同期アダプターを宣言します（`Ankole.IdentityProviders` が検証）。
- **`ai_gateway.provider`** — `Ankole.AIGateway.Providers` が検証するモデルプロバイダーアダプターを宣言し、`refresh` で AI Gateway にアクティブな宣言を公開します。
- **`agent_workers.provider_kind`** — Agent Worker インフラ種別（`Ankole.AgentWorkers.ProviderKind`）を宣言します。`refresh` で発見済み・アクティブな仕様を公開し、`veto_disable`（`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`）によって、いずれかのテナントに対象種別の割り当て済み Worker 行が残っている間はプラグインの無効化を拒否します。

サイトビルド全体では、ファーストパーティ拡張向けにコンパイル時・サイトスコープの拡張ポイントも提供されます。

- **`Ankole.Plugins.ConfigField`** — プラグインアダプターから Console や Pod の設定フォームへ型付きフィールド定義を公開します。
- **ドメイントランザクションフック（`hooks/0`）** — 所有ドメインのトランザクションおよびロック順序内で `Ankole.Plugins.Hook.before_commit_in_tx/2` を同期実行します。
- **外側 HTTP Plug** — ビルド選択された外側ルーターが、`AnkoleWeb.runtime_forward` でコアルーターへ転送する前にアドミッションチャレンジなどの Plug を実行します。
- **デュアルスコープ拡張 JSON:API ルート** — サイト Host と Pod Host 上の独立した `/api/v2/*` スコープ配下に型付き拡張 JSON:API ルートをマウントし、`Ankole.AuthZ.Authorizer` で認可します。
- **型付き UI スロット（`entries.json` `overrides`）** — 公開 Web アプリ（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`）をラップし、HTML シェルのアクティブプラグインスナップショット（`ankole-active-plugins`）および任意の OpenFeature `when` 条件に基づいて遅延コンポーネントを描画します。

プロセス再起動なしで動的に切り替える実行時フラグは、プラグインの有効化ではなく OpenFeature（`Ankole.Features`）で管理します。

## Cohort 監督ツリーと次回起動境界

セットアップ完了後の環境では、`:optional` プラグインはサイト全体でフェイルクローズとなり、PostgreSQL 上のグローバル `AppConfigure` キー `plugins.enabled_ids` で明示的に選択します。

`plugins.enabled_ids` の変更は**次回の Ankole プロセス起動**に向けてステージングされるだけで、実行中のプロセスやアダプター、設定定義をホットスワップしません。設定更新トランザクション内では `Ankole.Plugins.Contracts.veto_disable/2` が実行され、永続状態が依存しているプラグインの無効化を阻止します。

実行時には、`Ankole.Plugins.Cohort` が 1 つの不変な起動スナップショットの上で、`Ankole.Plugins.Registry` と `Ankole.Plugins.Supervisor` を `:rest_for_one` 戦略で監督します。

- `Ankole.Plugins.Registry` は起動時に一度だけスナップショットを解決し、アクティブ宣言の検証、プラグイン `AppConfigure` キーの登録、各サブシステムの `refresh`、`:persistent_term` へのスナップショット公開を行います。
- `Ankole.Plugins.Supervisor` はアクティブなプラグインの `children/0` を起動します。
- `Ankole.Plugins.Registry` がクラッシュした場合、`Ankole.Plugins.Cohort` は同じ不変の起動スナップショットから `Registry` と `Supervisor` の両方を再起動するため、起動後の設定変更が障害復旧中にアクティブ集合を変えることはありません。個別プラグインの子プロセスの障害は `Ankole.Plugins.Supervisor` 内に留まります。

## オペレーター API

サイト管理者は以下の 2 つの JSON:API ルートで Control Plane Plugins を確認・設定します。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 発見済みプラグインと `activation`、`configured_enabled`、`active`、`restart_required` 状態を一覧取得 |
| `PUT` | `/api/v2/site/control-plane-plugins` | `{ "data": { "id": string, "enabled": boolean } }` で次回プロセス起動向けに `:optional` プラグインを設定 |

両ルートとも特権テナントの `site_console:control_plane_plugins`（`read` および `update`）権限で保護されます。

## 責務の境界

Control Plane Plugins はコントロールプレーンと同じ BEAM ノード・信頼ドメインで動作します。Agent Computer Worker 向けのツールや Skill はここには含まれず、[Agent Library](../agent-library/) で管理されます。コントロールプレーンアダプターと関連する Agent Plugin は、それぞれ独立した有効状態を持ちます。

## 次のステップ

- プラグインが宣言するメッセージング・Webhook アダプターについては、[Signals](../signals/) を参照してください。
- `AppConfigure` キーとフィーチャーフラグについては、[AppConfigure](../app-configuration/) および [Console](../console-api/) を参照してください。
- サイト管理の認可モデルについては、[Principal and AuthZ](../principal-authz/) を参照してください。
