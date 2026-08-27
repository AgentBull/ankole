---
title: Agent Library
description: Agent Plugin、Skill、Control Plane Plugin を、全体または 1 つの Agent に対して有効化します。
section: User guide
order: 32
---

Agent Library は、Agent が使用できる仕事の方法と拡張を決定します。Console はそれらを 3 つのタイプに分けています。

これらは、この instance に既にインストールされている信頼できるコンポーネントです。Agent Library は公開 marketplace ではありません。ここで項目を有効化しても、インターネットから未知の code がダウンロードされることはありません。

## 3 種類の能力を理解する

| タイプ | 用途 | 変更が適用されるタイミング |
|---|---|---|
| **Agent Plugin** | 関連する Skill、MCP 能力、workspace template をまとめる | Agent の次の turn |
| **Skill** | 反復可能な 1 種類の仕事の手順とリソース | Agent の次の turn |
| **Control Plane Plugin** | chat adapter、identity source、設定、サービスを control plane に追加 | control plane の次回起動時 |

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

### Control Plane Plugin: 管理 platform を拡張する

Control Plane Plugin は OpenAI Plugin ではなく、Agent の作業 context に入りません。Ankole control plane を拡張します。

Control Plane Plugin は Channel Provider、identity source、システム設定、監督下の service を提供できます。これらのコンポーネントは起動構造を変えるため、有効化または無効化は control plane の次回起動時のみ適用されます。

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

### 有効化または無効化

Channel Provider、identity source、同様の platform 能力は Control Plane Plugin から提供されます。

1. **Control Plane Plugins** タブを開きます。
2. Plugin を見つけ、**次回起動時に有効** に設定します。
3. 保存して control plane を再起動します。
4. Agent Library に戻り、**現在 active** になっていることを確認します。
5. Plugin が提供する Channel Provider、identity source、または設定を構成します。

Docker Compose:

```bash
docker compose restart control-plane
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

Control Plane Plugin の無効化も次回起動時に適用されます。既存の Channel Provider や identity source を利用できなくする可能性があるため、無効化する前に active な configuration が依存していないことを確認してください。

## トラブルシューティング

### Agent Plugin と Skill

- **能力が見つからない:** deployment package に含まれているか確認してください。library はインストール済みのコンポーネントしか表示できません。
- **Skill は有効だが Agent が使えない:** 親の Agent Plugin が無効になっていないか確認し、新しい turn を開始してください。
- **Skill が一部の task にしか現れない:** `ankole-runtime` を確認してください。`main` の Skill は Background Agent Job に入らず、`background_job` の Skill は通常のメイン Agent の会話に入りません。
- **一部の Agent がグローバルな変更を無視する:** Agent ごとの override を持っている可能性があります。各 Agent の scope を選択して設定を確認してください。
- **Background Agent Job が workspace template を選択できない:** Agent Plugin がその Agent に対して有効であり、Plugin が `workspace-template/` を含むことを確認してください。

### Control Plane Plugin

- **Control Plane Plugin が「次回起動時に有効」と表示される:** 設定は保存されていますが、control plane はまだ再起動していません。
- **再起動後に control plane が起動しない:** 起動 log を読み、再度起動する前に Plugin の configuration または依存を修正してください。
- **Channel Provider がまだ見つからない:** Plugin が **現在 active** であることを確認し、その Channel Provider の configuration を検査してください。

両方の拡張方法については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。
