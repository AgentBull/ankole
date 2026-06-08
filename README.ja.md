# BullX — AI 同僚と並走するための AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[English](./README.md) | [简体中文](./README.zh-Hans.md)

BullX は、自律性を持つ AI 同僚と長期的に協働するための AgentOS です。

チャットボットは LLM に「会話」を与えました。OpenClaw や Hermes-Agent 世代は、channel、tool、skill、shell/browser、メモリファイル、SubAgent、定期タスクといった「手」を Agent に与えました。Dify、RPA、RAG ワークフロービルダーは、AI を特定業務アプリにパッケージ化しやすくしました。BullX が目指す次の段階は、AI 同僚が本当に入社した社員のように長期業務を担えるようにすること——役割の成果に責任を持ち、自らの判断で動き、結果から改善することです。

BullX の中心は AI 同僚そのものであり、見た目だけを変えた RAG カスタマーサービスボットでも、指示待ちのデジタルアシスタントでもありません。BullX Agent は、長期ミッション、KPI/OKR 型の成功指標、責任境界、長期記憶、外向きの ID を持つことを前提とします。長時間にわたり働き、人間や他 Agent と協働し、やり取りをまたいで永続履歴を保持できます。

BullX は「チャット入口を増やすこと」を目的にしません。現在のリポジトリは、より小さな runtime surface を中心に構成されています。

- **Principal と AuthZ** は、人間と Agent に安定した ID、グループ、外部 ID バインディング、権限付与を提供します。
- **Plugin runtime** は信頼済みローカルプラグインを読み込み、External Gateway adapter、identity-provider adapter、web provider、app-config 定義を登録させます。
- **External Gateway** は chat adapter が正規化した provider 事実を受け取り、外部可視状態の最新投影を保持し、agent 関連イベントを紐づく agent に配送し、outbox 経由で明示的な外向き intent を実行します。
- **AIAgent runtime** は conversation、message、LLM turn、generation lease、addressed/ambient 入力、slash-command stub、lifecycle revision、clarification、compression、web tool を所有します。
- **Setup と Console** は first-admin bootstrap、admin session、identity-provider setup、LLM provider 設定、Agent、chat-channel 設定を担当します。
- **PostgreSQL-backed state** が principal、設定、外部投影、gateway input/outbox row、AIAgent conversation record の永続的な真実です。Redis visible-output stream は弱い進行状態であり、最終真実ではありません。

いくつかの BullX product surface は、現在のリポジトリではまだ完全対応していなくても、中心的なモデルとして残ります。

- **Work** は、chat turn や assistant transcript ではなく、業務成果を所有するための business-facing unit です。
- **Brain** は、会話、外部イベント、意思決定、domain record、是正、結果から成長する長期 world model です。
- **Trajectory data** は、実際に起きた実行過程から後続の planning、skill、policy、execution を改善するための学習材料です。

## 誰のための BullX か

BullX が対象とするのは、本来「人を雇って」やらせる仕事です——誰かが専任で担う必要があるのに、人で埋められない・埋めたくない・まだ埋められない seat（席）です。

適合する席には 3 つの共通点があります：

- **本質的にリモート。** デジタル同僚に手はないので、仕事全体がキーボードの前で完結できる必要があります——リモート社員がやるように。
- **実際の成果で測れる。** その役割には誰でも検証できる具体的な成功指標があります：テストを通るコード、実 P&L のある戦略、ROAS に届くキャンペーン、期限内かつ事実誤りのないレポート、閲覧数とフォロワーの伸び。この指標こそが、同僚が自力で改善できる根拠であり、成果を信頼し「賃金に見合ったか」を判断できる根拠です。
- **受動的ではなく生産的。** その仕事はリクエストに答えるのを待つのではなく、何かを*生み出す*か、数字を*動かす*ものです。

これが指すのは第一線の IC（個人貢献者）職——エンジニア、quant 開発者、リサーチャー、運用型広告・グロース担当、コミュニティ運営、QA——であって、**次のものではありません**：

- **あなたを速くする copilot** —— BullX は仕事そのものを担い、あなたの作業を速めるのではありません。
- **カスタマーサービスや秘書 bot** —— ナレッジベースでリクエストに答えるのは、前世代の RAG アシスタントが既にカバーしています。
- **「AI 役員」** —— 判断・権限・説明責任は人の側に残り、同僚はそれを管理される実行者です。

BullX を思い浮かべるのは、ある席に担い手が要るのに人が足りない、その瞬間です。そこからは道具のように*操作*するのではなく、部下のように*管理*します——任務と指標を定め、成果をレビューし、軌道修正する。これは software よりも headcount に近いものです。そして BullX はオープンソースかつセルフホストなので、同僚を**自分で動かします**——その賃金は消費する compute であり、人を雇うのと同じく、結果が賃金に見合う限り雇い続けます。席課金のライセンスもなく、あなたと仕事の間にベンダーもいません。

## 3 つのモデル、1 つの本質的な違い

現在、多くのシステムが agent やデジタル従業員を名乗っていますが、最適化方向は異なります。

- **OpenClaw / Hermes 型アシスタント** は prompt 駆動の Agentic Loop です。個人アシスト、tool 呼び出し、channel 統合、cron、メモリファイル、skill、SubAgent に強みがあります。中核は prompt・スケジュール・メッセージで起動する assistant session のままです。
- **Dify / RPA / RAG workflow 型デジタルワーカー** は app / workflow 駆動の自動化です。CS ボット、BI レポートボット、請求書審査ボット、文書抽出など、境界が明確で繰り返し可能な処理に向きます。
- **BullX AI 同僚** は mission 駆動の仕事主体です。ここでの mission は単発タスクではなく、KPI や OKR に近い長期目的を意味します。権限、設定済み model / tool、記憶、外向き ID、責任境界を持ち、世界を観測し、重要性を判断し、人間や他 Agent と協働します。

| 観点 | OpenClaw / Hermes 型アシスタント | Dify / RPA / RAG workflow 型デジタルワーカー | BullX AI 同僚 |
| --- | --- | --- | --- |
| コア単位 | Agentic Loop または assistant session。 | App、Bot、RPA flow、または Workflow run。 | Principal に支えられ、永続的な conversation と external-event 文脈を持つ Agent。 |
| 自律性 | prompt、メッセージ、cron、ユーザー設定タスクに応答。 | 特定業務シナリオの既定フローを実行。 | Event を観測し、優先順位を付け、支援要請し、委譲し、長期 mission を前進。 |
| 行動 | Tool call、shell/browser 操作、メッセージ、ファイル、SubAgent。 | フォーム入力、API 呼び出し、抽出、ルーティング、承認、レポート生成。 | AIAgent generation、設定済み tool と web provider、External Gateway outbox 経由の provider-visible メッセージ。 |
| 記憶と推論 | Session memory、Markdown ファイル、skill notes、外部 memory layer。 | RAG ナレッジベース、workflow 変数、app 固有 state。 | 永続 conversation、summary、LLM turn、外部投影、そして Work と domain fact から成長する想定の Brain world model。 |
| 自己進化 | 過去 session から新しい skill や notes を学習。 | workflow やナレッジベースの手動更新に依存。 | Trajectory data で後続の planning、skill、policy、execution を改善する。現在の永続 conversation と turn record はその土台。 |
| 権限と予算 | 主に tool policy、model 設定、ローカル runtime 制御。 | app credential、node 権限、レート制限、workflow 設定。 | Principal ID、グループ membership、permission grant、外部 ID、設定済み provider credential。 |
| 人間協働 | approval prompt、DM gate、手動確認が一般的。 | フロー内の approval node や人手レビュー。 | 人間は上位・同位・下位として協働可能：承認、是正、エスカレーション、引き継ぎ、文脈補完、現実世界タスク支援、Agent からのタスク受領。 |
| 外部イベント | channel、cron、webhook、integration が assistant loop に入力。 | trigger で定義済み app / workflow を起動。 | External Gateway が provider-visible 事実を保持し、CloudEvents 形式のイベントを AIAgent conversation state に配送する。 |
| 説明責任 | Transcript と tool 履歴で 1 session を説明。 | Workflow log で 1 app run を説明。 | Work と product fact が所有成果を説明すべきであり、現在の永続記録は受け入れた外部事実、conversation state、assistant output、model turn、provider-visible side effect を説明する。 |

## なぜ BullX か

BullX は、前世代 agent システムの有用な表面（channel、tool、web access、plugin-provided integration、会話入口）を保持します。違いは永続的な事実の帰属先です。現在のリポジトリでは、永続状態は Principal/AuthZ row、External Gateway projection/outbox row、AIAgent conversation、message、summary、LLM turn などの PostgreSQL record に属します。想定する product model は、この基盤を Work、Brain、domain record、trajectory data へ拡張し、単発 assistant session transcript で止まりません。

BullX は Palantir 型 ontology エンジニアリングとも異なります。Brain は Work を通じて自然に成長すべきであり、day one に専門家が完全な業務グラフを定義することを要求しません。現在のコードは Brain をまだ完全には実装していませんが、会話、外部イベント、意思決定、是正、summary、将来の domain record が、その材料になります。価値が複利で積み上がるのもここです：土台のモデル知性は借り物で誰もが共有しますが、同僚が*あなたの*仕事を通じて、*あなた自身の*インフラ上で蓄える context はあなただけのものであり、席に長く就くほど深まります。

BullX が目指すのは「より良い bot」や「より賢い workflow app」ではなく、AI 同僚が観測・判断・委譲・待機・記憶・行動し、それらが担う成果によって評価される OS です。

## 期待する体験

**グループチャットは割り込まずに傍受できる。** カスタマーサクセス Agent は関連するグループチャット事実をミラーし、重要かどうかを判断し、最終的に Work を作成または更新してから、公開チャンネルではなく担当者へ私的に通知できます。

**1 つの入力を正しい実行経路へ流せる。** 顧客の予算凍結メッセージは External Gateway に保存され、agent event として配送されます。AIAgent は入力を正しい conversation に記録し、隣接する addressed message を batch し、ambient message を分けて保持し、明示的な provider-visible reply をキューできます。

**記憶は会話ログだけでなく世界を含める。** リサーチ Agent は会話を市場・政策・プロダクト・運用・外部イベントと合わせて理解すべきです。現在の保存基盤は conversation、summary、LLM turn、外部投影であり、Brain とより豊かな domain memory はこれらの事実の上に構築できます。

**世界モデルは人間同僚のように成熟できる。** BullX Agent はオンボーディング後、業務・業界・社内ルール・繰り返し現れる例外・暗黙知に徐々に習熟すべきであり、day one ですべてを組織側がモデリングし切る必要はありません。

**Agent は単発タスクではなく長期 mission を持てる。** Coding Agent、リサーチ Agent、カスタマーサクセス Agent は、複数のやり取りをまたいで継続的に働き、人間や他 Agent と協働し、trajectory data と永続履歴を後続の planning に活かせます。

**人間は Agent の上位・同位・下位として協働できる。** 人間は承認・是正だけでなく、同位として推進し、特定ケースを引き継ぎ、現実世界情報を補い、さらには Agent からタスク（例: オフライン確認、サイトの QR ログイン補助）を受けることもできます。

**仕事は雰囲気ではなく結果で評価できる。** 同僚は具体的な成功指標を持つ席に就きます——テストを通るコード、期限内かつ事実誤りのないレポート、目標に届くキャンペーン——だからその成果は、人間の同僚のそれと同じように検証し、信頼できます。

## ローカル開発ツール

このリポジトリには `@agentbull/devkit` が組み込まれており、エントリはルートのスクリプトです。

```shell
bun run kit --help
```

よく使うコマンド:

```shell
# VS Code workspace ファイルを作成・更新
bun run workspace:update

# ローカル Postgres / Redis を起動・停止（既定で公式 latest イメージを取得）
bun run services:start
bun run services:stop
bun run services:status

# app データベースを作成（既定 DB 名は app/.env.local または app/.env.development 由来）
bun run db:create

# app データベースを再構築し Drizzle migration を実行（破壊的操作、明示確認が必要）
bun run db:rebuild --yes
```

ローカル Compose ファイルは `tools/devkit/external-services.docker-compose.yml`。既定ポートは `app/.env.development` と整合し、Postgres は `localhost:5433`、Redis は `localhost:6379` です。
