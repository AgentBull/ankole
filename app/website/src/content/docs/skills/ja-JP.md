---
title: Agent Library
description: テナントおよび Agent 単位の Agent Plugin・Skill と、サイトスコープの Control Plane Plugin の管理方法を説明します。
section: User guide
order: 32
---

メンバーは **Meta Ankole → Skills** で完全な Skill パッケージを管理します。Console の **Agent Library** でも能力の有効・無効を設定でき、サイト管理者は Site Admin Console で Control Plane Plugin を管理します。組み込み Skill と Agent Plugin は Ankole に同梱され、権限のあるメンバーはカスタム Skill を作成またはインポートできます。

## 3 種類の能力を理解する

| タイプ | スコープ | 用途 | 変更が適用されるタイミング |
|---|---|---|---|
| **Agent Plugin** | テナント既定値 + Agent ごとの上書き | 関連する複数の Skill、MCP 機能、ワークスペーステンプレートを 1 つのパッケージにまとめる | Agent の次の Turn |
| **Skill** | 全 Agent で有効、または Agent を個別に指定 | 反復可能な単一業務の手順書と補助リソースを提供する | Agent の次の Turn |
| **Control Plane Plugin** | サイトスコープのみ（`/api/v2/site/control-plane-plugins`） | ビルド時にコンパイルされるフルスタック拡張（サブシステムアダプター、OTP サービス、HTTP Plug、拡張ルート、ドメインフック、設定フィールド、Web UI スロット） | ビルド時に常時有効（`activation: :always`）、またはコントロールプレーンの次回起動時（`activation: :optional`） |

### Agent Plugin: 1 つの package にまとめられた能力

Ankole の Agent Plugin は、<a href="https://developers.openai.com/plugins" target="_blank" rel="noreferrer">OpenAI Plugin</a> の上位互換（スーパーセット）として設計されています。

OpenAI Plugin は 1 つ以上の Skill、MCP サーバー、任意の UI を 1 つのパッケージに束ねる仕組みですが、Ankole はこの構造をそのまま踏襲したうえで、さらに **ワークスペーステンプレート（workspace template）** を追加しています。

そのため、単なるプロンプトの断片にとどまらず、「作業手順」「実行ツール」「タスク開始時の初期ディレクトリ環境」を一式まとめて Agent に提供できます。

Console で Agent Plugin を有効化すると、そのパッケージ一式が Agent から利用可能になります。パッケージに含まれる個々の Skill については、必要に応じて個別に有効化・無効化を切り替えることもできます。

#### workspace template は複雑な task を準備する

Agent Plugin には `workspace-template/` ディレクトリを含めることができます。Ankole が Background Agent Job を新規作成する際、このテンプレートの内容が新しい Job のワークスペースへコピーされます。

テンプレートには、`AGENTS.md`、作業用ディレクトリ構成、調査メソドロジー、検証スクリプト、Playbook、その他の補助ファイルを含められます。これにより、Job は最初から構造化され、更新や障害復旧にも対応した永続ワークスペース上で作業を開始できます。

代表的な実例が [Deep Research](../deep-research-job/) です。メイン Agent はまず会話の中でユーザーと調査要件をすり合わせ、その後 `deep-research` のワークスペーステンプレートを指定して Background Agent Job を起動します。

テンプレート側にあらかじめ調査ワークフロー、証拠保管用ディレクトリ、分析手法、検証ツールが揃っているため、Job は単一のワークスペース内で情報収集から分析の推敲、最終レポートの執筆までを一貫して進められます。

なお、ワークスペーステンプレートを持つ Agent Plugin を有効化しただけでは、進行中の会話に影響したり勝手に Job が作成されたりすることはありません。テンプレートからの初期化が行われるのは、実際にタスクがそのテンプレートを指定して新しい Job ワークスペースを作成する時点だけです。

### Skill: 反復可能な 1 つの仕事の方法

Ankole の Skill は、<a href="https://agentskills.io/specification" target="_blank" rel="noreferrer">公式の Agent Skills 仕様</a>に準拠しています。

各 Skill には YAML フロントマター付きの `SKILL.md` が少なくとも 1 つ含まれ、必要に応じて `scripts/`、`references/`、`assets/` ディレクトリを同梱できます。

Agent は最初、各 Skill の名前と概要説明（`description`）だけを参照します。そして現在のタスクに合致すると判断したときにはじめて、詳細な手順書や関連リソースを読み込みます。

Skill には特定の業務を完遂するための手順が記されています。作業の途中でリアルタイムデータの取得や外部認証、制御された操作が必要になる場合、Skill は対象の MCP ドメインツールを指定し、`mcporter` 経由で呼び出すことができます。なお、MCP カタログ全体がモデルに直接見える第 2 のツールレジストリとして公開されるわけではありません。

#### Ankole 拡張: Skill の実行 surface を選択する

Ankole では、標準のフロントマターを拡張して `ankole-runtime` フィールドをサポートしています。

```yaml
---
name: my-skill
description: Use for tasks that meet these conditions.
ankole-runtime: any
---
```

| 値 | Skill を利用できる実行面 | 適した用途 |
|---|---|---|
| `any` | メイン Agent と Background Agent Job の両方 | どちらの実行環境でも安全に完結できる作業（フィールド省略時の既定値） |
| `main` | メイン Agent の会話のみ | ユーザーへの確認質問、方針のすり合わせ、Background Agent Job の起動・管理を行う作業 |
| `background_job` | Background Agent Job のみ | 長時間かかる処理、Job ワークスペースを前提とする作業、単一 Job 内でファイル・ブラウザー操作・データ処理を完結させる作業 |

このフィールドは「どの実行面でその Skill を公開するか」を制御するものであり、設定しただけで自動的に Background Agent Job が作られるわけではありません。

たとえば Deep Research の入り口となる Skill は、元の会話で調査条件を確認してから Job を起動する役割を担うため `main` を指定しており、実際の調査を進める Skill 群は Background Agent Job 側で実行される構成になっています。

#### 共有 Skill パッケージ

各 Skill は必須の `SKILL.md` と付属ファイルで構成され、[Meta Ankole](../agent-library/) で管理します。有効化した Agent は `/drive/Skills/<slug>/` からパッケージ全体を読めます。`skill_view` はマニフェストを読み、参照ファイルは相対パスで明示的に読み込みます。Skill の指示は Brain の知識と別に管理します。

### Control Plane Plugin: サイトスコープのフルスタック拡張

Control Plane Plugin は OpenAI Plugin とは別物であり、Agent のプロンプトコンテキストに入ることも、テナント単位・Agent 単位で切り分けられることもありません。リリースバイナリに静的コンパイルされるサイトスコープのプラットフォーム拡張であり、ノード起動時に解決されて不変の `:persistent_term` スナップショットとして公開されます。

Control Plane Plugin は、プラットフォーム全体にわたって次の拡張ポイントを提供できます。

- サブシステムアダプター（`signals.adapter`、`principals.identity_provider`、`ai_gateway.provider`、`agent_workers.provider_kind`）および監視下の OTP プロセス（`children/0`）
- 外側の HTTP エッジ `Plug` とスコープ付きの拡張 JSON:API ルート
- 同期ドメイントランザクションフック `hooks/0`（`Ankole.Plugins.Hook`）
- 宣言的な `AppConfigure` 設定フィールド（`ConfigFields`）と型付き Web UI スロット（`entries.json` の `overrides`）

各 Control Plane Plugin は `activation: :optional | :always` を宣言します。任意有効のプラグイン（既定の `:optional`）は `plugins.enabled_ids` で選択し、コントロールプレーンの次回起動時に反映されます。一方、`activation: :always` を宣言したコアプラグインはビルド時点で常時有効に固定されており、無効化できません。再起動を伴わずに即座に挙動を切り替える動的スイッチや段階的ロールアウトには、OpenFeature（`Ankole.Features`）を使用します。

## Agent Plugin と Skill を管理する

### Skill を有効にする

**Meta Ankole → Skills** で Skill を選択します。管理者は全 Agent で有効にするか、AI 同僚を個別に指定できます。各メンバーは自分のアシスタントを設定できます。全体スイッチがオンの間、個別スイッチは有効表示で固定されます。オフに戻すと保存済みの個別設定が復元されます。カスタム Skill は作成時には無効です。

Agent Plugin 内の Skill には、親 Plugin の有効化も必要です。変更は次の Turn から適用されます。既存のバックグラウンド Job には作成時の能力の許可リストが適用されます。

### Agent Plugin を設定する

Console の **Agent Library** で**グローバル既定値**を選んで Plugin の既定値を設定するか、Agent を選び、**グローバルに従う**、**有効**、**無効**を指定します。親 Plugin を無効にすると配下の Skill は利用できなくなりますが、個別設定は維持されます。

### Skill 教訓を確認する

Agent は Skill 本体の手順とあわせて、日付付きの短い作業上の注意事項（Skill 教訓）を受け取ることができます。Dreaming が Job の実行記録からリース付きの教訓を自動生成するほか、運用者が手動で教訓を追加することもでき、いずれの場合も共有の `SKILL.md` 本体は変更されません。

確認・管理するには、Agent Library のスコープを対象の Agent に変更して該当する Skill カードを開きます。カード上には現在有効な教訓と廃止済みの教訓、根拠となった証拠 Job、再確認日、廃止理由が表示され、その場で教訓の追加や廃止を行えます。廃止した教訓は、次の Turn から Agent に渡されなくなります。

なお、全 Agent に共通する一般的なルールを各 Agent の教訓へ個別にコピーして回らないでください。全体に適用すべきルールは Skill 本体のソースに記述します。証拠条件、リース期間、関連設定の詳細については [Skill 教訓](../skill-lessons/) を参照してください。

## Control Plane Plugin を管理する

### 任意のサイトプラグインを有効化または無効化する

Control Plane Plugin はサイトスコープ専用（`/api/v2/site/control-plane-plugins`）であり、Site Admin Console（`/site-admin-console`）で Agent Library のスコープを **グローバル既定値** に合わせたときにのみ表示されます。

1. Site Admin Console で **Agent Library** を開き、スコープを **グローバル既定値** にしたまま **Control Plane Plugins** タブを選択します。
2. 対象の任意プラグイン（`activation: :optional`）を探し、**次回起動時に有効** に切り替えます（`activation: :always` のプラグインはビルド固定のため切り替えトグルは表示されません）。
3. 設定を保存し、コントロールプレーンを再起動します。
4. 再起動後に **Control Plane Plugins** タブを再度開き、ステータスが **現在 active** になっていることを確認します。
5. そのプラグインが提供する Channel Provider、Identity ソース、Worker プロバイダー、または関連設定を構成します。

Docker Compose 環境での再起動：

```bash
docker compose restart control-plane
```

Kubernetes 環境での再起動：

```bash
kubectl -n ankole rollout restart deployment/ankole-control-plane
```

任意の Control Plane Plugin を無効化する場合も、同じく次回起動時に反映されます。なお、設定変更のトランザクション内では `veto_disable` による参照整合性チェックが強制されます。そのため、Worker プロバイダー系プラグインについては、いずれかのテナント内にそのプロバイダー種別を参照する Worker（一時停止中の Worker や削除処理中の Agent を含む）が 1 つでも残っている間は無効化できません。無効化する前に、稼働中の Channel Provider、Identity ソース、Worker がそのプラグインに依存していないことを確認してください。再起動なしの動的な機能切り替えには OpenFeature（`Ankole.Features`）を使用します。

## トラブルシューティング

### Agent Plugin と Skill

- **目的の能力が見つからない：** インストール済みのパッケージと選択したスコープを確認してください。カスタム Skill は Meta Ankole で作成またはインポートします。公式パッケージはデプロイに含まれている必要があります。
- **Skill を有効にしたのに Agent が使えない：** 親の Agent Plugin が無効になっていないか確認したうえで、新しい Turn を開始してください。
- **一部のタスクでしか Skill が現れない：** `ankole-runtime` の設定を確認してください。`main` 指定の Skill は Background Agent Job には渡されず、`background_job` 指定の Skill は通常のメイン Agent 会話には渡されません。
- **Plugin の既定値が一部の Agent に反映されない：** その Agent の Plugin 上書き設定を確認してください。Skill は全体スイッチと個別設定で有効・無効が決まります。
- **Background Agent Job でワークスペーステンプレートを選べない：** 対象の Agent で該当する Agent Plugin が有効になっているか、およびその Plugin に `workspace-template/` が含まれているかを確認してください。

### Control Plane Plugin

- **Control Plane Plugins タブが表示されない：** Control Plane Plugin はサイトスコープ専用です。Site Admin Console（`/site-admin-console`）を開き、**Agent Library** のスコープを **グローバル既定値** に切り替えてください。
- **ステータスが「次回起動時に有効」のまま変わらない：** 設定自体は `plugins.enabled_ids` に保存されていますが、起動時のスナップショットを更新するにはコントロールプレーンの再起動が必要です。
- **プラグインを無効化できない：** `activation: :always`（ビルド固定有効）が宣言されているか、あるいはいずれかのテナントの Agent Worker がその Worker プロバイダー種別を参照しているために `veto_disable` でブロックされています。
- **再起動後にコントロールプレーンが立ち上がらない：** 起動ログを確認し、プラグインの設定値や依存関係の不備を修正してから再起動してください。
- **有効化したのに Channel Provider がまだ表示されない：** プラグインのステータスが **現在 active** になっているかを確認し、該当 Channel Provider の設定内容を見直してください。

Skill と Control Plane Plugin の双方の開発方法については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。
