---
title: Skill と Control Plane Plugin の開発
description: Agent に業務手順を教える Skill の作成方法と、サイトスコープのアダプター・設定・ドメイントランザクションフック・常駐サービス・Web UI スロットを追加する Control Plane Plugin の開発方法を説明します。
section: Developer guide
order: 113
---

Skill と Control Plane Plugin はどちらも Ankole を拡張する仕組みですが、対象とするレイヤーと解決する課題がまったく異なります。実装を始める前に、目的に合った拡張ポイントを選んでください。

| やりたいこと | 使う拡張ポイント |
|---|---|
| 特定の業務の進め方や判断手順を Agent に教える | Skill |
| MCP 連携を使ったワークフローと呼び出し手順を Agent に提供する | Skill |
| 新しい IdP、チャットアダプター、LLM Provider、または Worker プロバイダー種別を追加する | Control Plane Plugin |
| サイトスコープの設定項目、監視下の OTP サービス、ドメイントランザクションフック、拡張 `/api/v2` ルート、または Web UI スロットを追加する | Control Plane Plugin |
| 再起動を伴わずに実行時のビジネス挙動を動的に切り替える | OpenFeature（`Ankole.Features`） |

Skill は Agent が実行時に読み取るファイル群であり、コントロールプレーンの再ビルドは不要です。これに対し、Control Plane Plugin はリリースバイナリにコンパイルされるサイトスコープ専用のファーストパーティ製フルスタック拡張です（テナント単位や Agent 単位にスコープされることはありません）。`:optional` のプラグインは `siteadmin` が有効化した後の次回起動時に有効化され、`:always` のプラグインはソースビルド時点で常時有効に固定されます。

## Skill を書く

Skill の実体は、`SKILL.md` を含む 1 つのディレクトリです。必要に応じて補助資料（references）、テンプレート、`agents/openai.yaml` などを同梱できます。

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

ディレクトリ名には英小文字、数字、ハイフン、アンダースコアを使用します。システム同梱の組み込み Skill は `app/library/skills/` 配下に置かれ、個別インストールされた Skill は各 Agent のファイル領域に配置されます。

### frontmatter を書く

`SKILL.md` 先頭の YAML フロントマターによって、Skill の検索発見と有効化条件を制御します。

```yaml
---
name: my-skill
description: "Use when the Agent must review a vendor contract."
default_enabled: true
category: productivity
tags: [Contracts]
ankole-runtime: background_job
platforms: [linux]
---
```

Agent は `description` の文面を見てその Skill を開くかどうかを判断するため、「どのような依頼や状況のときに使うべきか」という具体的なトリガー条件を記述してください。専用ワークスペースでの分離実行が必要な作業には `ankole-runtime: background_job` を指定し、Linux 固有のコマンドやツールに依存する場合にのみ `platforms: [linux]` を指定します。

### 同梱 Skill を Brain から発見できるようにする

すべてのプロンプトのカタログに常時載せる必要はないものの、進行中の作業と意味的に関連したタイミングで呼び出せるようにしたい SOP や専門メソドロジーには、`brain-recall-only` を設定します。

```yaml
---
name: idea-lineage
description: Trace how one idea evolved through memory — first mention, best articulation, reversals, and the current live version, each cited from stored evidence.
tags:
  - idea lineage
  - how my thinking evolved
brain-recall-only: true
---
```

このフィールドを利用できるのは、システム同梱の単体 Skill および Agent Plugin 内の同梱 Skill のみです（Agent が後から個別インストールした Skill ではこの発見モードは使えません）。同梱 Skill の `name` はグローバルに一意である必要があり、Agent Plugin に含まれていても名前空間プレフィックスは付与されません。Brain は標準の Skill メタデータから `lazyload-agent-skills/<name>` の発見用レコードを自動生成します。

なお、Skill のフロントマターに `slug`、`type`、`title`、`aliases` といった Brain オブジェクト用のフィールドを追加しないでください。Brain は `name`、`description`、`tags` を対象に検索を行い、名前とタグを使って自然言語からの照合を行います。`SKILL.md` の本文や同梱ファイル、Agent 固有の Skill 教訓が Brain インデックスへ直接取り込まれることはなく、発見後も必ず `skill_view` ツール経由で読み取られます。

### 本文を書く

社内固有のローカルルールを知らない有能な実務担当者へ業務を引き継ぐつもりで、次の 5 点を明確に記述します。

1. どのような場面でこの Skill を使うか。
2. 最初に入力として何を読み取るか。
3. 作業を進める具体的な順序。
4. 最終的に提出すべき成果物の形式と基準。
5. 禁止事項、または事前に人間の承認が必要な操作。

同梱の参考資料（`reference.md` など）やテンプレートファイルがある場合は、必ず `SKILL.md` の本文からファイル名付きでリンクを張ってください。Agent は必要になったファイルだけをオンデマンドで読みに行くため、メインの手順書から案内されていないファイルの存在を知ることはできません。

### MCP 依存を宣言する

MCP サーバーへの実行時依存関係がある場合は、`agents/openai.yaml` で宣言します。

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

ここで宣言した MCP 依存関係は、その Skill が有効になっている間だけ実行環境へ注入されます。`SKILL.md` 本文では使用するドメインツール名と選択基準を明記し、選定した 1 ツールだけを `mcporter list server.tool --schema --json` で確認させたうえで、標準入力（stdin）に JSON 引数を渡して呼び出させるように案内してください。詳細なスキーマ仕様は [MCP リファレンス](../mcp/) を参照してください。

### Skill を検証する

検証用の Agent で作成した Skill を有効化し、実際の業務に近いタスクを依頼して動作を確かめます。Agent が迷わず対象の Skill を選び、必要な補助ファイルを読み取り、完了基準どおりに出力できるかを確認してください。そもそも Skill が選ばれない場合は `description` のトリガー表現を見直し、実行手順がぶれる場合は本文のステップ順序と制約条件をより具体的に書き直します。

`brain-recall-only` を設定した Skill については、通常のシステムプロンプト内カタログに出てこないこと、および名前・説明・タグを手がかりに Brain 検索で発見できることもあわせて確認します。そのうえで、互換性のある実行面では `skill_view` で全文を読み込め、互換性のない実行面では適切なルーティング案内または拒否応答が返ることを検証してください。最後に Skill（または親の Agent Plugin）を無効化し、同じ Agent から検索発見も読み込みもできなくなることを確認します。

## Control Plane Plugin を開発する

コントロールプレーン側が所有するサイトスコープの機能を追加する場合は、Control Plane Plugin として実装します。プラグインモジュールは `Ankole.Plugins.Plugin` ビヘイビアを実装し、最小構成では不変のプラグイン ID を 1 つ返すだけで成立します。

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

プラグイン ID には英小文字のスラッグを使用してください。その他のコールバックはすべて任意であり、必要な拡張ポイントだけを実装します。

| コールバック | 用途 |
|---|---|
| `activation/0` | `:optional`（既定値。`plugins.enabled_ids` で選択し次回起動時に反映）または `:always`（ビルド時に常時有効で固定、Console 上の切り替えトグルなし） |
| `display_name/0`、`description/0` | Site Admin Console 上に表示するローカライズ済みの表示名と説明文 |
| `adapter_declarations/0` | IdP、チャット、LLM Provider、Worker プロバイダー（`agent_workers.provider_kind`）、Webhook などのサブシステムアダプターを宣言 |
| `hooks/0` | 同期ドメイントランザクションフック（`Ankole.Plugins.Hook` を実装する `[{hook_point, module}]` のリスト）を宣言 |
| `app_config_definitions/0` | 固定キーの `AppConfigure` 設定項目を宣言 |
| `app_config_patterns/0` | 動的 ID を含むパターン型の `AppConfigure` 設定項目を宣言 |
| `children/0` | プラグイン Supervisor 配下で常駐させる接続プロセス、レジストリ、Reconciler などを定義 |

さらにフルスタックのビルド拡張として、コアルーターの外側に HTTP リクエスト `Plug` を差し込んだり、型付きの `/api/v2/*` JSON:API ルートをマウントしたり、`entries.json` の `overrides` を使って型付き Web UI スロット（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`）を差し替えたりすることも可能です。

### Plugin を登録する

作成したモジュールを `config/config.exs` のリストに追加します。

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

登録すると、**Site Admin Console**（`/site-admin-console` の **Global defaults** スコープ、API は `GET` / `PUT /api/v2/site/control-plane-plugins`）のサイトスコープカタログに表示されるようになります。`siteadmin` が `:optional` プラグインを有効化すると、コントロールプレーンの次回起動時に不変の `:persistent_term` ブートスナップショットとして解決され、設定項目、アダプター、フック、監視下の OTP プロセスが一括で登録されます（なお、いずれかのテナントが該当する Worker プロバイダー種別を参照している間は、`veto_disable` によって無効化が拒否されます）。`:always` プラグインはリリースに含まれている時点で自動的に有効化されます。ホットロードには対応していないため、再起動なしで動的に切り替えるポリシー制御には OpenFeature（`Ankole.Features`）を使ってください。

### adapter を宣言する

サブシステム向けのアダプターを公開するには、`adapter_declarations/0` から宣言マップのリストを返します。どのサブシステムがその宣言を受け取るかは `contract_id` で指定します。

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

アダプター固有の必須フィールドは、受け入れ側の各サブシステムで定義されています。たとえばチャットアダプターであれば [Signals](../signals/) の契約に従い、IdP、モデル Provider、Worker プロバイダーもそれぞれのサブシステムが提供する標準レジストリへ統合されます。プラグイン内部に独自の並行した設定管理経路を作らないでください。

### 設定、hook、service を宣言する

運用者が稼働中に変更できる設定項目には、`app_config_definitions/0` または `app_config_patterns/0` を使用します。OS の環境変数は、PostgreSQL に接続できるようになる前のブートストラップ段階で必須となる値にだけ限定してください。

主要なドメイントランザクション（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）に対して同期的な受付検査やクォータ制限を組み込みたい場合は、`hooks/0` を使用します。各フックモジュールは `Ankole.Plugins.Hook.before_commit_in_tx/2` を実装し、呼び出し元と同一のトランザクション内で `:ok` または `{:error, reason}` を返します（エラーを返すとトランザクション全体がロールバックされます）。

常駐プロセスが必要な場合は、`children/0` から標準の OTP child specification を返します。外部接続や Reconciler はプラグイン専用の Supervisor 配下にぶら下がり、プラグインが有効化された起動時に立ち上がり、無効化後の次回起動時には起動されなくなります。

### Plugin を検証する

コントロールプレーンのユニットテストと静的解析を実行します。`:optional` プラグインの場合は **Site Admin Console**（`/site-admin-console`）で有効化してからコントロールプレーンを再起動し（`:always` プラグインは起動時からそのまま有効になります）、ステータスが active になること、追加した設定項目が表示されること、トランザクションフックが契約どおり動作すること、そして宣言した各アダプターが実際の通信接続を確立できることを確認してください。外部プロトコルを実装するプラグインでは、対応する統合テスト（integration test）もあわせて実行します。

## 続きを読む

- Skill の有効化、スコープ継承、個別管理については、[Agent Library](../skills/) を参照してください。
- プラグインの解決と起動時スナップショットの詳細については、[Control Plane Plugins](../control-plane-plugins/) を参照してください。
- 新しい LLM Provider の実装手順については、[Provider の追加](../adding-a-provider/) を参照してください。
