---
title: AppConfigure
description: Console で Ankole の AppConfigure 実行時設定を管理し、組み込みの設定キーを参照します。
section: User guide
order: 43
---

**Console → AppConfigure** には、デプロイメント インスタンスの稼働中に管理者が変更できる設定が表示されます。例としては、永続 memory、Agent の実行上限、企業 directory の同期間隔、plugin の有効/無効スイッチなどがあります。

LLM Provider、Identity Provider、chat channel、環境変数は、それぞれ専用の Console ページがあります。ここで再度設定する必要はありません。

## AppConfigure と環境変数

AppConfigure 設定は PostgreSQL に保存されます。これらはインスタンスの稼働中における Ankole の製品動作を制御します。ほとんどの変更は後続の作業に適用され、再デプロイは不要です。

[デプロイ環境変数](../environment-variables/) は control plane、PostgreSQL、Worker の起動に使われます。変更後は該当するプロセスを再起動してください。

Skill、コマンドラインツール、MCP service が API key などのカスタム値を必要とする場合は、[Agent 環境変数](../worker-env/) を使用してください。

## 設定の探し方

このページでは関連する設定がグループ化されています。キー名または説明で検索できるほか、グループを開いてまとめて確認できます。

各行には次のいずれかの状態があります。

- **編集可能:** 行を開いて、ここで変更できます。
- **読み取り専用:** 行には現在の状態が表示されますが、ここでは変更できません。
- **別の場所で管理:** 管理リンクをたどって、設定を所有する Console ページを開きます。

キーは設定の安定した名前です。説明には、その設定が何を制御するかと、数値がどの単位を使うかが書かれています。

## 適用範囲と値の出所を理解する

AppConfigure ページが変更するのはインスタンスレベルの上書きです。**インスタンスまたは Agent** とマークされたキーは、所有する機能が 1 つの Agent に対して上書きを保存できるようにしますが、このページで Agent を選択したり編集したりすることはできません。

Ankole が Agent に対してこれらの設定を解決するときは、次の順序を使います。

1. 現在の Agent による上書き
2. インスタンスレベルの上書き
3. インストールされているバージョンが宣言するデフォルト値

AppConfigure の一覧には、インスタンスレベルの上書きまたはバージョンのデフォルト値が表示されます。**Reset to default** はインスタンスレベルの上書きを削除します。その結果、独自の上書きを持たないすべての Agent が、バージョンのデフォルト値を使うようになります。

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
| `ai_agent.max_iterations` | インスタンスまたは Agent | 1 回の Agent turn で許可されるモデルの最大反復回数 |
| `ai_agent.max_output_tokens` | インスタンスまたは Agent | 1 回のモデル応答に対する出力 token の上限 |
| `ai_agent.inactivity_timeout_ms` | インスタンスまたは Agent | 非アクティブなモデルまたは Provider を、turn を終了するまで待つ時間 |
| `ai_agent.library.agent_plugin_defaults` | インスタンス | Agent Plugin のデフォルトの有効状態 |
| `ai_agent.library.skill_defaults` | インスタンス | Skill のデフォルトの有効状態 |

### AI Gateway と長期 memory

| キー | 適用範囲 | 用途 |
|---|---|---|
| `ai_gateway.compaction` | インスタンス | 会話履歴の自動圧縮ポリシー |
| `brain.knowledge` | インスタンス | 長期 memory の投影予算と結果数の上限 |
| `brain.dreaming` | インスタンスまたは Agent | Dreaming と知識キュレーションのポリシー |
| `brain.embedding` | インスタンス | Embedding モデルとベクトル次元数 |
| `brain.search` | インスタンス | 長期 memory の減衰と再ランキングのポリシー |
| `brain.sources` | インスタンス | 外部ソースの同期と保持のポリシー |

### Identity、Plugin、インスタンスのデフォルト値

| キー | 適用範囲 | 用途 |
|---|---|---|
| `principals.identity_providers.active` | インスタンス、読み取り専用 | 管理者のサインインに使える Identity ソース。Identity Provider ページで管理 |
| `principals.identity_providers.directory_full_sync_interval_hours` | インスタンス | 組織 directory の全量同期間隔 |
| `plugins.enabled_ids` | インスタンス | 次回起動時に有効にする Control Plane Plugin |
| `system.timezone` | インスタンス | schedule など control plane 機能が使うデフォルトのタイムゾーン |
| `i18n.default_locale` | インスタンス | Ankole インターフェースのデフォルト言語 |

### Worker、web 読み取り、セキュリティ

| キー | 適用範囲 | 用途 |
|---|---|---|
| `runtime_fabric.worker_auth_key` | インスタンス、読み取り専用 | control plane と Worker の間の認証キー。システムが生成・管理 |
| `agent_computer.background_agent_job.max_turns_per_worker` | インスタンス | 各 Worker で同時に実行できる Background Agent Job turn の最大数 |
| `worker.rendered_fetch_idle_ttl_ms` | インスタンスまたは Agent | 組み込みの `web_fetch` レンダリングフォールバックのアイドル保持時間 |
| `security.ssrf_filter` | インスタンスまたは Agent | モデルが制御する fetch が private、loopback、link-local、CGNAT アドレスへのアクセスを拒否するかどうか |

この設定がオフであっても、クラウドメタデータのアドレスは拒否されます。

### 初回セットアップの状態

| キー | 適用範囲 | 用途 |
|---|---|---|
| `setup.bootstrap_activation_code` | インスタンス、読み取り専用 | 初回セットアップページ用の一時アクティベーションコード |
| `setup.completed` | インスタンス、読み取り専用 | このインスタンスが初回セットアップを完了したかどうか |

これらのキーは初回セットアップのフローが所有します。アクティベーションコードを確認するには、`kit show bootstrap-activation-code` を実行してください。このキーを AppConfigure ページで編集しないでください。

## 暗号化設定

Ankole は credential 設定を暗号化して保存し、一覧とエディタではマスクを表示します。マスクのまま保存すると現在の値が維持されます。新しい内容を入力すると置き換えられます。

現在の値を確認する必要がある場合にのみ、**Reveal** を使用してください。表示された credential を chat、スクリーンショット、ticket にコピーしないでください。
