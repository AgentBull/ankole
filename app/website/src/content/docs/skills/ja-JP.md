---
title: Agent Library
description: テナントおよび Agent 単位の Agent Plugin と Skill、ならびにサイトスコープの Control Plane Plugin を管理します。
section: User guide
order: 32
---

Site Admin Console の **Agent Library** ページでは、2 つの異なる拡張境界を管理します。テナントおよび個別 Agent スコープのモデル能力（**Agent Plugin** と **Skill**）と、厳密に**サイトスコープ**のプラットフォーム拡張（**Control Plane Plugin**。スコープが **グローバル既定値** のときのみ表示）です。

これらはすべて、このデプロイインスタンスにコンパイルまたはパッケージ済みで同梱されている信頼されたファーストパーティ製コンポーネントです。Agent Library は公開マーケットプレイスではなく、ここで項目を有効化してもインターネットから未知のコードがダウンロードされることはありません。

## 3 種類の能力を理解する

| タイプ | スコープ | 用途 | 変更が適用されるタイミング |
|---|---|---|---|
| **Agent Plugin** | テナント既定値 + Agent ごとの override | 関連する Skill、MCP 能力、workspace template をまとめる | Agent の次の turn |
| **Skill** | テナント既定値 + Agent ごとの override | 反復可能な 1 種類の仕事の手順とリソース | Agent の次の turn |
| **Control Plane Plugin** | サイトスコープのみ（`/api/v2/site/control-plane-plugins`） | ビルド時コンパイルのフルスタック拡張（サブシステムアダプター、OTP サービス、HTTP Plug、拡張ルート、ドメインフック、設定フィールド、Web UI スロット） | ビルドで常時有効（`activation: :always`）、または control plane の次回起動時（`activation: :optional`） |

### Agent Plugin: 1 つの package にまとめられた能力

Ankole Agent Plugin は、<a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a> の superset です。

OpenAI Plugin は、1 つ以上の Skill、MCP server、任意の UI を 1 つの package にまとめられます。Ankole はこの構造を保持し、**workspace template** を追加します。

したがって、Agent Plugin は仕事の方法、実行 tool、task の初期環境をまとめて提供できます。1 つの prompt 以上のものです。

Console で Agent Plugin を有効にすると、その package が Agent に利用可能になります。個々の Skill は引き続き個別に有効化または無効化できます。

#### workspace template は複雑な task を準備する

`workspace-template/` ディレクトリは Agent Plugin に属します。Ankole が Background Agent Job を作成するとき、この template を新しい Job の workspace にコピーできます。

template は `AGENTS.md`、ディレクトリ、調査方法、validation script、Playbook、その他の task file を提供できます。Job は更新と復旧が可能な durable な workspace を受け取ります。

Ankole の最先端の [Deep Research](../deep-research-job/) は代表的な例です。メイン Agent はまず調査の依頼を確認し、その後 `deep-research` workspace template を使って Background Agent Job を作成します。

template は調査の workflow、証拠のディレクトリ、分析方法、validation tool を提供します。Job は 1 つの workspace で source を収集し、分析を改訂し、最終 report を作成できます。

workspace template を持つ Agent Plugin を有効にしても、既存の会話は変わらず、Job も作成されません。Ankole が新しい Job workspace を初期化するのは、task がその template を選択したときだけです。

### Skill: 反復可能な 1 つの仕事の方法

Ankole の Skill は、<a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">公式の Agent Skills specification</a> に準拠しています。

各 Skill は、YAML frontmatter を持つ `SKILL.md` を少なくとも 1 つ含みます。`scripts/`、`references/`、`assets/` を含めることもできます。

Agent は最初に名前と説明を見ます。task が一致した後でのみ、完全な手順と必要なリソースを読み込みます。

Skill は、ある種類の仕事の完了方法を説明します。workflow がライブデータ、認証、または制御された action を必要とする場合、Skill は MCP domain tool を選択し、mcporter を通じて呼び出すことができます。MCP catalog は model に見える第二の tool registry ではありません。

#### Ankole 拡張: Skill の実行 surface を選択する

Ankole は標準 frontmatter に `ankole-runtime` を追加します。

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| 値 | Skill が利用できる場所 | こんなときに使う |
|---|---|---|
| `any` | メイン Agent と Background Agent Job | どちらの実行 surface でも安全に完了できる仕事。フィールドがない場合の既定値でもある |
| `main` | メイン Agent の会話のみ | ユーザーに質問する、選択を確認する、Background Agent Job を作成・管理する必要がある仕事 |
| `background_job` | Background Agent Job のみ | 長時間実行される、Job workspace に依存する、または 1 つの Job で file、browser 作業、データを処理する仕事 |

このフィールドは Skill がどこで見えるかを制御します。Background Agent Job を作成するものではありません。

Deep Research のエントリ Skill は `main` を使用します。元の会話で依頼を確認し、Job を作成するからです。調査用の Skill は Background Agent Job 内で実行できます。

#### Ankole 拡張: Brain から Skill を発見する

一部の SOP や方法論は、現在の作業に関連するときだけ役立ちます。すべての Prompt に表示すると context を浪費します。同梱 Skill は `brain-recall-only: true` を宣言できます。これは標準 Skill のままであり、Agent Plugin、Skill の有効化、実行 surface、`skill_view` の規則も変わりません。違いは、model に見える Skill カタログへ入れず、Brain が意味に基づいて発見することです。

Brain は Skill の名前、説明、tag を検索します。一致した後、Agent は `skill_view` を呼び出します。`skill_view` は `ankole-runtime` に従い、互換性のある実行 surface では Skill を読み込み、それ以外では正しい routing または rejection の結果を返します。Skill または親 Agent Plugin を無効にすると、その Agent は Brain から発見することも読み込むこともできません。この意味検索の経路には、有効な Brain が必要です。この mode は、必要なときだけ利用でき、すべての Prompt を常に占有すべきではない同梱の方法論や SOP に適しています。

### Control Plane Plugin: サイトスコープのフルスタック拡張

Control Plane Plugin は OpenAI Plugin ではなく、Agent の作業 context にも入らず、テナント単位や Agent 単位でスコープされることもありません。リリースに静的コンパイルされるサイトスコープの拡張であり、ノード起動時に解決されて不変の `:persistent_term` スナップショットとして公開されます。

Control Plane Plugin はフルスタックで以下の拡張ポイントを提供できます。

- サブシステムアダプター（`signals.adapter`、`principals.identity_provider`、`ai_gateway.provider`、`agent_workers.provider`）および監督下の OTP プロセス（`children/0`）
- 外側の HTTP エッジ `Plug` とスコープ付き拡張 JSON:API ルート
- 同期ドメイントランザクション `hooks/0`（`Ankole.Plugins.Hook`）
- 宣言的な `AppConfigure` 設定フィールド（`ConfigFields`）と型付き Web UI スロット（`entries.json` の `overrides`）

各 Control Plane Plugin は `activation: :optional | :always` を宣言します。任意のプラグイン（既定の `:optional`）は `plugins.enabled_ids` で選択し、control plane の次回起動時に適用されます。`activation: :always` を持つプラットフォームプラグインはソースビルドで常時有効に固定され、無効化できません。再起動なしで即座に切り替える動的ランタイムスイッチや段階的ロールアウトには、OpenFeature（`Ankole.Features`）を使用します。

## Agent Plugin と Skill を管理する

### instance の既定値を設定する

1. Console で **Agent Library** を開きます。
2. scope を **グローバル既定値** に設定します。
3. **Agent Plugins** または **Skills** で能力を見つけます。
4. その既定値を有効化または無効化します。

グローバル既定値は、新しい Agent と override を持たない Agent に適用されます。既に開始した turn は変わりません。Agent は次の turn で新しい能力セットを読み取ります。

一般的でリスクの低い能力は既定で有効にし、例外に対して狭めます。

少数の役割にしか適用されない能力、特別な credential を必要とする能力、または実質的な risk がある能力は、既定で無効にし、必要な場所でのみ有効化する方が管理しやすくなります。

### 1 つの Agent を override する

1. Agent Library の上部で、scope を対象の Agent に変更します。
2. Agent Plugin または Skill を見つけます。
3. **グローバルに従う**、**有効**、**無効** のいずれかを選択します。

**グローバルに従う** は例外を削除します。その後 instance の既定値を変更すると、この Agent にも適用されます。明示的な有効または無効の値は、その Agent の override として残ります。

Agent Plugin は複数の Skill を含むことができます。親を無効にするとその Skill は利用できなくなりますが、各 Skill の設定は書き換えられません。親を再度有効にすると、Skill はそれぞれの実効状態に戻ります。

### Skill 教訓を確認する

Agent は、完全な Skill 手順と共に、日付付きの作業上の注意事項を受け取れます。Dreaming は Job の証拠からリース付きの教訓を作り、運用者は人の教訓を追加できます。共有の `SKILL.md` は変わりません。

Agent Library の scope を対象の Agent に変更し、Skill card を見つけます。card には、有効な教訓と廃止済みの教訓、証拠 Job、再確認日、廃止理由が表示されます。運用者は教訓を追加または廃止できます。Agent は次の turn から廃止済み教訓を読みません。

一般的な規則を各 Agent の教訓にコピーしないでください。すべての Agent に適用する規則は、Skill の source に記述します。証拠の規則、リース、設定については [Skill 教訓](../skill-lessons/) を参照してください。

## Control Plane Plugin を管理する

### 任意のサイトプラグインを有効化または無効化する

Control Plane Plugin は厳密にサイトスコープ（`/api/v2/site/control-plane-plugins`）であり、Site Admin Console（`/site-admin-console`）で Agent Library のスコープを **グローバル既定値** に設定したときのみ表示されます。

1. Site Admin Console で **Agent Library** を開き、スコープを **グローバル既定値** にしたまま **Control Plane Plugins** タブを開きます。
2. 任意の Plugin（`activation: :optional`）を見つけ、**次回起動時に有効** に設定します。`activation: :always` の Plugin はビルドで固定有効のため無効化トグルはありません。
3. 保存して control plane を再起動します。
4. **Control Plane Plugins** タブに戻り、**現在 active** になっていることを確認します。
5. Plugin が提供する Channel Provider、identity source、Worker プロバイダー、または設定を構成します。

Docker Compose:

```bash
docker compose restart control-plane
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

任意の Control Plane Plugin の無効化も次回起動時に適用されます。設定トランザクション内では `veto_disable` 参照チェックが強制されるため、Worker プロバイダー Plugin は、いずれかのテナントでそのプロバイダー種別を参照する Worker（一時停止中の Worker や削除処理中の Agent を含む）が割り当てられている間は無効化できません。無効化する前に、稼働中の Channel Provider、identity source、Worker が依存していないことを確認してください。再起動なしの動的な機能切り替えには OpenFeature（`Ankole.Features`）を使用します。

## トラブルシューティング

### Agent Plugin と Skill

- **能力が見つからない:** deployment package に含まれているか確認してください。library はインストール済みのコンポーネントしか表示できません。
- **Skill は有効だが Agent が使えない:** 親の Agent Plugin が無効になっていないか確認し、新しい turn を開始してください。
- **Skill が一部の task にしか現れない:** `ankole-runtime` を確認してください。`main` の Skill は Background Agent Job に入らず、`background_job` の Skill は通常のメイン Agent の会話に入りません。
- **一部の Agent がグローバルな変更を無視する:** Agent ごとの override を持っている可能性があります。各 Agent の scope を選択して設定を確認してください。
- **Background Agent Job が workspace template を選択できない:** Agent Plugin がその Agent に対して有効であり、Plugin が `workspace-template/` を含むことを確認してください。

### Control Plane Plugin

- **Control Plane Plugins タブが表示されない:** Control Plane Plugin はサイトスコープ専用です。Site Admin Console（`/site-admin-console`）を開き、**Agent Library** のスコープを **グローバル既定値** に切り替えてください。
- **Control Plane Plugin が「次回起動時に有効」と表示される:** 設定は `plugins.enabled_ids` に保存されていますが、起動スナップショットを更新するには control plane の再起動が必要です。
- **Control Plane Plugin を無効化できない:** その Plugin が `activation: :always`（ビルド固定有効）を宣言しているか、いずれかのテナントの Agent Worker がその Worker プロバイダー種別を参照しているため `veto_disable` によって拒否されています。
- **再起動後に control plane が起動しない:** 起動 log を読み、再度起動する前に Plugin の configuration または依存を修正してください。
- **Channel Provider がまだ見つからない:** Plugin が **現在 active** であることを確認し、その Channel Provider の configuration を検査してください。

両方の拡張方法については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。
