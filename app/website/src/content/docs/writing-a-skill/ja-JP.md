---
title: Skill と Control Plane Plugin の開発
description: Agent に仕事の方法を追加するか、サイトスコープの adapter、設定、ドメイントランザクション hook、監督下の service、Web UI スロットを control plane に追加します。
section: Developer guide
order: 113
---

Skill と Control Plane Plugin はどちらも Ankole を拡張しますが、解決する問題は異なります。code を書く前に、正しい拡張ポイントを選んでください。

| 要件 | 使用するもの |
|---|---|
| Agent にある種類の仕事のやり方を教える | Skill |
| Agent に MCP-backed の workflow と使用手順を提供する | Skill |
| IdP、chat adapter、LLM Provider、Worker provider kind を追加する | Control Plane Plugin |
| サイトスコープの control plane 設定、監督下の service、ドメイントランザクション hook、拡張 `/api/v2` ルート、または Web UI スロットを追加する | Control Plane Plugin |
| 再起動なしで runtime のビジネス挙動を動的に切り替える | OpenFeature（`Ankole.Features`） |

Skill は Agent が読み取る file の集合です。新しい control plane の build は不要です。Control Plane Plugin はリリースにコンパイルされるサイトスコープのファーストパーティフルスタック拡張です（テナントや Agent スコープになることはありません）。`:optional` Plugin は `siteadmin` が有効化した後の次回起動時に活性化し、`:always` Plugin はソース build に固定で活性化されます。

## Skill を書く

Skill は `SKILL.md` を含むディレクトリです。references、templates、`agents/openai.yaml` を含めることもできます。

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

ディレクトリ名には小文字、数字、ハイフン、またはアンダースコアを使用してください。組み込みの Skill は `app/library/skills/` にあります。インストールされた Skill は、その Agent の file space に置かれます。

### frontmatter を書く

`SKILL.md` の先頭にある YAML が、発見と有効化を制御します。

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

`description` は具体的な trigger を述べる必要があります。Agent はそれを使って Skill を読み取るかどうかを判断するからです。Job の分離が必要な仕事には `ankole-runtime: background_job` を設定します。Skill が Linux の tool を必要とする場合のみ、`platforms: [linux]` を設定します。

### 同梱 Skill を Brain から発見できるようにする

すべての Prompt に表示する必要はないが、現在の作業と意味的に関連するときに発見すべき SOP や方法論には、`brain-recall-only` を使用します。

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

このフィールドを使用できるのは、同梱の standalone Skill と Agent Plugin 内の Skill だけです。Agent がインストールした Skill は、この発見 mode を使用しません。同梱 Skill の名前は引き続きグローバルに一意であり、Agent Plugin への所属によって namespace は追加されません。Brain は標準 Skill metadata から `lazyload-agent-skills/<name>` の発見レコードを自動的に派生します。

Skill に `slug`、`type`、`title`、`aliases` などの Object フィールドを追加しないでください。Brain は `name`、`description`、`tags` を検索し、名前と tag を自然言語の解決に使います。Skill の本文、その他すべての Skill file、Agent 固有の教訓は Brain に入りません。発見後も `skill_view` からだけ読み取れます。

### 本文を書く

あなたのローカルな規則を知らない有能な Agent のために書きましょう。次のことを述べます。

1. いつ Skill を使うか。
2. どの input を読み取るか。
3. 仕事の順序。
4. 必要な結果。
5. 禁止されている、または承認が必要な action。

各 reference と template は `SKILL.md` から名前でリンクしてください。Agent は必要なときだけこれらの file を読み取るため、メインの手順が特定していない file は使用できません。

### MCP 依存を宣言する

MCP の実行依存を `agents/openai.yaml` で宣言します。

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

この依存が利用できるのは、Skill が有効である間だけです。`SKILL.md` では、domain tool と選択規則を名前で示し、Agent には `mcporter list server.tool --schema --json` で選択した tool だけを検査させ、stdin への JSON で呼び出させます。完全な contract は [MCP リファレンス](../mcp/) を参照してください。

### Skill を検証する

テスト用の Agent で Skill を有効にし、実際の task を与えてください。Agent が Skill を選択し、必要な file を読み取り、完了基準に従うことを確認します。選択に失敗する場合は `description` を改善します。実行が不安定な場合は、順序と制約を明示します。

`brain-recall-only` Skill では、通常の Prompt に表示されないことと、Brain が名前、説明、tag から発見できることも確認してください。`skill_view` が互換性のある実行 surface では完全な Skill を読み込み、互換性のない surface では既存の routing または rejection の動作を保つことを確認します。その後、Skill または親 Agent Plugin を無効にし、同じ Agent が発見も読み込みもできないことを確認します。

## Control Plane Plugin を開発する

control plane が所有するサイトスコープの能力には、Control Plane Plugin を使用します。module は `Ankole.Plugins.Plugin` を実装します。最小の有効な Plugin は、1 つの安定した ID を持ちます。

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Plugin ID には小文字の slug を使用してください。任意の callback は必要なときだけ実装します。

| Callback | 用途 |
|---|---|
| `activation/0` | `:optional`（デフォルト、`plugins.enabled_ids` で選択し次回起動時に反映）または `:always`（ビルドに固定で活性化、Console トグルなし） |
| `display_name/0`、`description/0` | Site Admin Console に表示されるローカライズされた名前と説明 |
| `adapter_declarations/0` | IdP、chat、LLM Provider、Worker provider（`agent_workers.provider_kind`）、webhook などの adapter を宣言 |
| `hooks/0` | 同期ドメイントランザクション hook（`Ankole.Plugins.Hook` を実装する `[{hook_point, module}]`）を宣言 |
| `app_config_definitions/0` | 固定的な AppConfigure 設定を宣言 |
| `app_config_patterns/0` | 動的な ID を持つ設定を宣言 |
| `children/0` | Plugin supervisor の下で connection、registry、reconciler を起動 |

フルスタックのビルド拡張では、コアルーターの外側にリクエスト Plug を挟んだり、型付きの `/api/v2/*` JSON:API ルートをマウントしたり、`entries.json` の `overrides` で型付き Web UI スロット（`PodAppSlots`、`ConsoleAppSlots`、`AuthAppSlots`）をバインドしたりすることもできます。

### Plugin を登録する

module を `config/config.exs` に追加します。

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

すると Plugin が **Site Admin Console**（`/site-admin-console` の **Global defaults** スコープ、`GET` / `PUT /api/v2/site/control-plane-plugins`）のサイトスコープ catalog に表示されます。`siteadmin` が `:optional` Plugin を有効化すると、control plane の次回起動時に不変の `:persistent_term` ブートスナップショットへ解決され、設定、adapter、hook、監督下の process が登録されます（いずれかのテナントが Worker provider kind を参照している間は `veto_disable` により無効化が拒否されます）。`:always` Plugin はリリースにコンパイルされていれば自動的に活性化します。Plugin はホットロードをサポートしません。再起動なしで動的に切り替えるポリシーには OpenFeature（`Ankole.Features`）を使用してください。

### adapter を宣言する

`adapter_declarations/0` は adapter の宣言を返します。`contract_id` が、各宣言を読み取る subsystem を選択します。

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

adapter 固有のフィールドは、所有する subsystem が定義します。chat adapter は [Signals](../signals/) の contract に従います。IdP、モデル Provider、Worker provider は既存の registry を使用します。Plugin 内に並行した configuration 経路を作らないでください。

### 設定、hook、service を宣言する

運用者が runtime で管理する設定には、`app_config_definitions/0` または `app_config_patterns/0` を使用します。環境変数は、database が利用可能になる前に存在しなければならない起動時事実にのみ使用します。

ドメイントランザクション（`:create_agent`、`:create_invitation`、`:enable_signal_binding`、`:enable_identity_provider`、`:store_file`、`:commit_files`、`:create_pod_page`、`:restore_pod_page`、`:insert_base_records`、`:admit_compute`）に同期的な受付検査やクォータ検査を追加するには、`hooks/0` を使用します。各 hook module は `Ankole.Plugins.Hook.before_commit_in_tx/2` を実装し、呼び出し元のトランザクション内で `:ok` または `{:error, reason}` を返します（エラーはトランザクションをロールバックします）。

`children/0` は標準の OTP child specification を返します。connection と reconciler は Plugin の supervisor の下に置きます。これらは Plugin の活性化時に起動し、次回起動時の無効化後に停止します。

### Plugin を検証する

control plane のテストと静的検査を実行します。`:optional` Plugin の場合は **Site Admin Console**（`/site-admin-console`）で有効にして control plane を再起動します（`:always` Plugin は起動時にそのまま活性化します）。Plugin が active で、設定が表示され、hook が契約どおり動作し、宣言した各 adapter が実際の connection を完了することを確認します。Plugin が外部 protocol を実装する場合は、関連する integration test を実行します。

## 続きを読む

- Skill の有効化、継承、インストールについては、[Agent Library](../skills/) を参照してください。
- 発見と活性化については、[Control Plane Plugins](../control-plane-plugins/) を参照してください。
- 新しい LLM Provider については、[Provider の追加](../adding-a-provider/) を参照してください。
