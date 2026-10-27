---
title: Agent Library
description: テナントおよび Agent 単位の Agent Plugin・Skill と、サイトスコープの Control Plane Plugin の管理方法を説明します。
section: User guide
order: 32
---

Site Admin Console の **Agent Library** ページでは、性質の異なる 2 つの拡張境界を管理します。1 つはテナントおよび個別 Agent スコープのモデル能力（**Agent Plugin** と **Skill**）、もう 1 つは厳密に**サイトスコープ**で管理されるプラットフォーム拡張（**Control Plane Plugin**。スコープを **グローバル既定値** に合わせたときのみ表示）です。

いずれも、デプロイインスタンスのビルド時またはパッケージング時に同梱された信頼できるファーストパーティ製コンポーネントです。Agent Library は外部の公開マーケットプレイスではないため、ここで項目を有効化してもインターネットから未知のコードがダウンロードされることはありません。

## 3 種類の能力を理解する

| タイプ | スコープ | 用途 | 変更が適用されるタイミング |
|---|---|---|---|
| **Agent Plugin** | テナント既定値 + Agent ごとの上書き | 関連する複数の Skill、MCP 機能、ワークスペーステンプレートを 1 つのパッケージにまとめる | Agent の次の Turn |
| **Skill** | テナント既定値 + Agent ごとの上書き | 反復可能な単一業務の手順書と補助リソースを提供する | Agent の次の Turn |
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

#### Ankole 拡張: Brain から Skill を発見する

特定の業務でしか使わない SOP（標準作業手順書）や専門メソドロジーをすべてのプロンプトに毎回載せていると、コンテキストウィンドウを無駄に消費してしまいます。そこで同梱 Skill では `brain-recall-only: true` を宣言できます。これを有効にしても、Agent Plugin との親子関係、有効・無効の切り替え、実行面（`ankole-runtime`）、および `skill_view` のルールは通常の Skill と変わりません。唯一の違いは、モデルに常時提示する Skill カタログからは除外し、代わりに Brain が意味検索によって必要なタイミングで発見できるようにする点です。

Brain は Skill の名前、説明、タグを対象に検索を行います。関連する Skill が見つかると、Agent は `skill_view` を呼び出して内容を読み込みます。このとき `skill_view` は `ankole-runtime` の制約に従い、現在の実行面と互換性があれば本文を返し、互換性がなければ適切なルーティング案内または拒否応答を返します。Skill または親の Agent Plugin が無効化されている場合は、Brain の検索結果にも現れず読み込むこともできません。なお、この発見経路を利用するには Brain が有効になっている必要があります。常時プロンプトを占有させたくない専門手順書や SOP に最適なモードです。

### Control Plane Plugin: サイトスコープのフルスタック拡張

Control Plane Plugin は OpenAI Plugin とは別物であり、Agent のプロンプトコンテキストに入ることも、テナント単位・Agent 単位で切り分けられることもありません。リリースバイナリに静的コンパイルされるサイトスコープのプラットフォーム拡張であり、ノード起動時に解決されて不変の `:persistent_term` スナップショットとして公開されます。

Control Plane Plugin は、プラットフォーム全体にわたって次の拡張ポイントを提供できます。

- サブシステムアダプター（`signals.adapter`、`principals.identity_provider`、`ai_gateway.provider`、`agent_workers.provider`）および監視下の OTP プロセス（`children/0`）
- 外側の HTTP エッジ `Plug` とスコープ付きの拡張 JSON:API ルート
- 同期ドメイントランザクションフック `hooks/0`（`Ankole.Plugins.Hook`）
- 宣言的な `AppConfigure` 設定フィールド（`ConfigFields`）と型付き Web UI スロット（`entries.json` の `overrides`）

各 Control Plane Plugin は `activation: :optional | :always` を宣言します。任意有効のプラグイン（既定の `:optional`）は `plugins.enabled_ids` で選択し、コントロールプレーンの次回起動時に反映されます。一方、`activation: :always` を宣言したコアプラグインはビルド時点で常時有効に固定されており、無効化できません。再起動を伴わずに即座に挙動を切り替える動的スイッチや段階的ロールアウトには、OpenFeature（`Ankole.Features`）を使用します。

## Agent Plugin と Skill を管理する

### instance の既定値を設定する

1. Console で **Agent Library** を開きます。
2. スコープを **グローバル既定値** に設定します。
3. **Agent Plugins** または **Skills** から対象の項目を探します。
4. 既定の状態（有効または無効）を切り替えます。

グローバル既定値は、今後新しく作成する Agent および個別の上書き設定（override）を持たないすべての Agent に適用されます。すでに実行中の Turn には影響せず、次の Turn から新しい能力セットが読み込まれます。

汎用性が高くリスクの低い機能はグローバル既定で有効にし、不要な Agent だけ個別に絞り込む運用がシンプルです。

反対に、限られた役割でしか使わない機能、専用の認証情報を必要とする機能、あるいは操作リスクの大きい機能は、グローバル既定では無効にしておき、必要な Agent にだけ個別に有効化する方が安全に管理できます。

### 1 つの Agent を override する

1. Agent Library 画面の上部で、スコープを対象の Agent に切り替えます。
2. 対象の Agent Plugin または Skill を探します。
3. **グローバルに従う**、**有効**、**無効** のいずれかを選択します。

**グローバルに従う** を選ぶと個別設定が解除され、以降グローバル既定値を変更した際にこの Agent にもそのまま反映されるようになります。**有効** または **無効** を明示的に選んだ場合は、その Agent 専用の上書き設定として維持されます。

なお、複数の Skill を内包する親の Agent Plugin を無効化すると配下の Skill もすべて利用できなくなりますが、各 Skill の個別設定自体は書き換えられずに保持されます。親 Plugin を再度有効化すれば、各 Skill は元の有効・無効状態にそのまま戻ります。

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

- **目的の機能が見当たらない：** デプロイパッケージに同梱されているか確認してください。Agent Library にはインストール済みのコンポーネントしか表示されません。
- **Skill を有効にしたのに Agent が使えない：** 親の Agent Plugin が無効になっていないか確認したうえで、新しい Turn を開始してください。
- **一部のタスクでしか Skill が現れない：** `ankole-runtime` の設定を確認してください。`main` 指定の Skill は Background Agent Job には渡されず、`background_job` 指定の Skill は通常のメイン Agent 会話には渡されません。
- **一部の Agent にグローバル既定値の変更が効かない：** その Agent に個別の上書き設定（override）が入っている可能性があります。スコープを該当 Agent に切り替えて確認してください。
- **Background Agent Job でワークスペーステンプレートを選べない：** 対象の Agent で該当する Agent Plugin が有効になっているか、およびその Plugin に `workspace-template/` が含まれているかを確認してください。

### Control Plane Plugin

- **Control Plane Plugins タブが表示されない：** Control Plane Plugin はサイトスコープ専用です。Site Admin Console（`/site-admin-console`）を開き、**Agent Library** のスコープを **グローバル既定値** に切り替えてください。
- **ステータスが「次回起動時に有効」のまま変わらない：** 設定自体は `plugins.enabled_ids` に保存されていますが、起動時のスナップショットを更新するにはコントロールプレーンの再起動が必要です。
- **プラグインを無効化できない：** `activation: :always`（ビルド固定有効）が宣言されているか、あるいはいずれかのテナントの Agent Worker がその Worker プロバイダー種別を参照しているために `veto_disable` でブロックされています。
- **再起動後にコントロールプレーンが立ち上がらない：** 起動ログを確認し、プラグインの設定値や依存関係の不備を修正してから再起動してください。
- **有効化したのに Channel Provider がまだ表示されない：** プラグインのステータスが **現在 active** になっているかを確認し、該当 Channel Provider の設定内容を見直してください。

Skill と Control Plane Plugin の双方の開発方法については、[Skill と Control Plane Plugin の開発](../writing-a-skill/) を参照してください。
