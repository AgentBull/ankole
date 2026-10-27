---
title: Control Plane Plugins
description: コントロールプレーンにおけるファーストパーティ Elixir 拡張モデル。アクティベーションモード、サブシステム契約、トランザクションフック、Cohort 監督ツリー、および次回起動時の有効化境界を説明します。
section: Developer guide
order: 110
---

Control Plane Plugins は、信頼されたファーストパーティの Elixir/OTP コードによって Ankole サイトの機能を拡張する仕組みです。プラグインは `Ankole.Plugins` を通じて、`AppConfigure` の設定キー、各種サブシステムアダプター、同期トランザクションフック、および監視対象の子プロセスを追加できます。

Control Plane Plugins はリリースビルドにコンパイルされるファーストパーティの Elixir モジュール（`:control_plane_plugin_modules`）であり、実行時に外部から未知のコードを読み込むマーケットプレイスやサンドボックス機構ではありません。アプリケーション起動時に検出と検証が行われ、`:optional` プラグインはサイト全体の有効化リストに従って次回のプロセス起動時に有効化されます。一方、`activation: :always` を宣言したプラグインはビルドに含まれている限り常にアクティブになります。

## 発見済みとアクティブの 2 段階

実行時のプラグインには、次の 2 つの段階があります。

- **発見済み（Discovered）** — リリースにコンパイルされ、起動時の検証を通過したすべてのプラグインモジュールです。運用者は Site Admin Console 上でカタログ全体を確認できます。
- **アクティブ（Active）** — `activation/0` が `:always` であるプラグイン、または `activation/0` が `:optional` かつ `plugins.enabled_ids` に含まれているプラグインです（なお、初回セットアップ `setup.completed` が完了する前は、発見済みの全プラグインがアクティブとして扱われます）。`AppConfigure` 定義の登録、サブシステムアダプターやドメインフックの公開、監視付き子プロセスの起動を行うのは、アクティブなプラグインだけです。

発見済みであっても非アクティブなプラグインは、管理カタログ上に表示され PostgreSQL 上の既存 `AppConfigure` 保存値も維持されますが、実行時の設定定義・アダプター・フック・プロセスとしては一切登録されません。

## プラグイン契約

各プラグインモジュールは `Ankole.Plugins.Plugin` ビヘイビアを実装します。必須のコールバックは次の 1 つだけです。

- **`plugin_id/0`** — 正規表現 `~r/\A[a-z][a-z0-9_-]*\z/` に一致する一意な英小文字スラッグを返します。

それ以外のコールバックはすべて任意です。

- **`activation/0`** — `:optional | :always` を返します（既定値は `:optional`）。`:optional` は `plugins.enabled_ids` の設定に従い、`:always` はビルドに含まれる限り常時有効となって無効化リクエストを拒否します。
- **`display_name/0`**、**`description/0`** — 管理画面表示用のローカライズ済みテキストマップを返します。
- **`app_config_definitions/0`**、**`app_config_patterns/0`** — プラグインが追加する `Ankole.AppConfigure` キーおよびパターン定義を返します。
- **`adapter_declarations/0`** — プラグインを各サブシステム契約へ接続するためのアトムキー付き宣言リストを返します。ブラウザー設定フォーム向けのスキーマ定義には `Ankole.Plugins.ConfigField` を使用します。
- **`hooks/0`** — 同期トランザクションフック `[{hook_point, module}]` のリストを返します。各モジュールは宣言されたフックポイント（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）に対して `Ankole.Plugins.Hook.before_commit_in_tx/2` を実装し、`{:error, reason}` を返すことで呼び出し元のデータベーストランザクションをロールバックできます。
- **`children/0`** — プラグインランタイムのスーパーバイザー配下で起動する `Supervisor.child_spec()` のリストを返します。

起動時には `Ankole.Plugins.Spec.from_module/1` がこれらを読み取って検証済みの `Spec` を組み立てます。構造上の不備、プラグイン ID の重複、またはサブシステム契約の検証エラーが見つかった場合、アプリケーションは該当モジュールを明示したうえで起動を停止します。

## サブシステム契約とサイト拡張ポイント

`Ankole.Plugins.Contracts` には 5 種類のサブシステムアダプター契約が定義されています。各契約は起動時の `validate` に加え、必要に応じてアクティブ状態の反映（`refresh`）や無効化防止ガード（`veto_disable`）を備えています。

- **`signals.adapter`** — `Ankole.Signals.Adapters` で検証されるメッセージング・イベントアダプターを宣言し、Signal Bindings および Conversations の配信で利用できるようにします。
- **`signals.webhook_handler`** — `/webhooks/v1/:handler_id/:instance_id/:kind` で受け付ける HTTP Webhook ハンドラーを宣言します（`Ankole.Signals.WebhookHandlers` が検証）。
- **`principals.identity_provider`** — エンタープライズ Identity Provider およびディレクトリ同期アダプターを宣言します（`Ankole.IdentityProviders` が検証）。
- **`ai_gateway.provider`** — `Ankole.AIGateway.Providers` で検証されるモデルプロバイダーアダプターを宣言し、`refresh` によってアクティブな宣言を AI Gateway に公開します。
- **`agent_workers.provider_kind`** — Agent Worker のインフラ種別（`Ankole.AgentWorkers.ProviderKind`）を宣言します。`refresh` で発見済み・アクティブな仕様を公開するとともに、いずれかのテナントに対象種別の割り当て済み Worker レコードが残っている間は `veto_disable`（`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`）によってプラグインの無効化を拒否します。

さらにサイトビルド全体では、ファーストパーティ拡張向けにコンパイル時・サイトスコープの拡張ポイントも用意されています。

- **`Ankole.Plugins.ConfigField`** — プラグインアダプターから Console や Pod の設定フォームへ、型付きフィールド定義を公開します。
- **ドメイントランザクションフック（`hooks/0`）** — 対象ドメインのトランザクションおよびロック順序の内側で、`Ankole.Plugins.Hook.before_commit_in_tx/2` を同期実行します。
- **外側 HTTP Plug** — ビルド時に選択された外側ルーターが、`AnkoleWeb.runtime_forward` でコアルーターへリクエストを渡す前に、アドミッションチャレンジなどの Plug を実行します。
- **デュアルスコープ拡張 JSON:API ルート** — サイト Host と Pod Host 上の独立した `/api/v2/*` スコープ配下に型付き拡張 JSON:API ルートをマウントし、`Ankole.AuthZ.Authorizer` で認可を行います。
- **型付き UI スロット（`entries.json` の `overrides`）** — 公開 Web アプリ（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`）をラップし、HTML シェルに埋め込まれたアクティブプラグイン一覧（`ankole-active-plugins`）および任意の OpenFeature `when` 条件にもとづいて遅延ロードコンポーネントを描画します。

なお、プロセスを再起動せずに動的に切り替える実行時フラグについては、プラグインの有効化機構ではなく OpenFeature（`Ankole.Features`）で管理します。

## Cohort 監督ツリーと次回起動境界

初回セットアップ完了後の環境では、`:optional` プラグインは既定で無効（フェイルクローズ）となり、PostgreSQL 上のグローバル `AppConfigure` キー `plugins.enabled_ids` に含めることで明示的に有効化します。

`plugins.enabled_ids` を更新しても、実行中のプロセスやアダプター、設定定義がその場でホットスワップされるわけではなく、**次回の Ankole プロセス起動時**に向けて設定がステージングされます。なお、設定更新トランザクションの中で `Ankole.Plugins.Contracts.veto_disable/2` が呼ばれるため、既存の永続データが依存しているプラグインを誤って無効化することはできません。

実行時には、`Ankole.Plugins.Cohort` が不変の起動時スナップショットを保持し、配下の `Ankole.Plugins.Registry` と `Ankole.Plugins.Supervisor` を `:rest_for_one` 戦略で監督します。

- `Ankole.Plugins.Registry` は起動時に一度だけスナップショットを解決し、アクティブ宣言の検証、プラグイン由来 `AppConfigure` キーの登録、各サブシステムの `refresh` 呼び出し、および `:persistent_term` へのスナップショット公開を行います。
- `Ankole.Plugins.Supervisor` はアクティブな各プラグインの `children/0` を起動します。
- 万が一 `Ankole.Plugins.Registry` がクラッシュした場合、`Ankole.Plugins.Cohort` は起動時に確定した同じ不変スナップショットを使って `Registry` と `Supervisor` の両方を再起動します。そのため、起動後に設定値が変更されていても、障害復旧の途中でアクティブなプラグイン集合が変わってしまうことはありません。また、個別プラグインの子プロセスで起きた障害は `Ankole.Plugins.Supervisor` 内に封じ込められます。

## オペレーター API

サイト管理者は、次の 2 つの JSON:API ルートから Control Plane Plugins の状態確認と設定変更を行えます。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 発見済みプラグインの一覧と、`activation`・`configured_enabled`・`active`・`restart_required` の各状態を取得 |
| `PUT` | `/api/v2/site/control-plane-plugins` | `{ "data": { "id": string, "enabled": boolean } }` を送り、次回プロセス起動時の `:optional` プラグインの有効／無効を設定 |

どちらのルートも、特権テナントの `site_console:control_plane_plugins`（`read` および `update`）権限によって保護されています。

## 責務の境界

Control Plane Plugins は control plane と同一の BEAM ノードおよび信頼ドメイン内で動作します。一方、Agent Computer Worker 上で動くツールや Skill はここには含まれず、[Agent Library](../agent-library/) 側で管理されます。control plane 側のアダプターと関連する Agent Plugin は、それぞれ独立した有効化状態を持ちます。

## 次のステップ

- プラグインが宣言するメッセージング・Webhook アダプターの詳細については、[Signals](../signals/) を参照してください。
- `AppConfigure` キーやフィーチャーフラグの運用については、[AppConfigure](../app-configuration/) および [Console](../console-api/) を参照してください。
- サイト管理操作の認可モデルについては、[Principal and AuthZ](../principal-authz/) を参照してください。
