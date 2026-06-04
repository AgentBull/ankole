# BullX — AI 同僚と並走するための AgentOS

BullX は、自律性を持つ AI 同僚と長期的に協働するための AgentOS です。

チャットボットは LLM に「会話」を与えました。OpenClaw や Hermes-Agent 世代は、channel、tool、skill、shell/browser、メモリファイル、SubAgent、定期タスクといった「手」を Agent に与えました。Dify、RPA、RAG ワークフロービルダーは、AI を特定業務アプリにパッケージ化しやすくしました。BullX が目指す次の段階は、監査可能・復旧可能・ガバナンス可能・継続改善可能な運用モデルの中で、AI 同僚が長期業務を担えるようにすることです。

BullX の中心は AI 同僚そのものであり、見た目だけを変えた RAG カスタマーサービスボットでも、指示待ちのデジタルアシスタントでもありません。BullX Agent は、長期ミッション、KPI/OKR 型の成功指標、責任境界、長期記憶、権限、外向きの ID を持つことを前提とします。長時間にわたり働き、人間や他 Agent と協働し、軌跡データから改善できます。

BullX は「チャット入口を増やすこと」を目的にしません。AI 同僚を持続的な仕事システムに編成します。

- **Agent** は長期ミッション、責任境界、権限、記憶、外向き ID、KPI/OKR 型成功指標を担います。
- **IMGateway とその他 Gateway** は外部世界の事実を保持し、CloudEvents mail を発行します。
- **MailBox** は AIAgent、Workflow、SubAgent、gateway、blackhole など Receiver 向けの内部配送エントリを作成します。
- **Receiver** は実作業を担当します。多くは柔軟な判断を行う AIAgent、または明示的なプロセス構造を表現する Workflow です。
- **Principal**、**Budget**、そして人間協働メカニズムにより、高リスク行動の前に責任・コスト・権限を明確化します。
- **Capability** は model、tool、browser、sandbox、メッセージチャネル、API、外部 agent harness を公開しつつ、実行権限を prompt に隠しません。
- **Brain** は長期記憶と世界モデル推論を提供します。生のベクトルログでも、肥大化する Markdown メモリでも、最初から完全定義された ontology でもなく、対話・イベント・行動・結果から抽出・修正・統合される知識です。

## 3 つのモデル、1 つの本質的な違い

現在、多くのシステムが agent やデジタル従業員を名乗っていますが、最適化方向は異なります。

- **OpenClaw / Hermes 型アシスタント** は prompt 駆動の Agentic Loop です。個人アシスト、tool 呼び出し、channel 統合、cron、メモリファイル、skill、SubAgent に強みがあります。中核は prompt・スケジュール・メッセージで起動する assistant session のままです。
- **Dify / RPA / RAG workflow 型デジタルワーカー** は app / workflow 駆動の自動化です。CS ボット、BI レポートボット、請求書審査ボット、文書抽出など、境界が明確で繰り返し可能な処理に向きます。
- **BullX AI 同僚** は mission 駆動の仕事主体です。ここでの mission は単発タスクではなく、KPI や OKR に近い長期目的を意味します。権限、予算、記憶、外向き ID、責任境界を持ち、世界を観測し、重要性を判断し、人間や他 Agent と協働し、軌跡データから改善します。

| 観点 | OpenClaw / Hermes 型アシスタント | Dify / RPA / RAG workflow 型デジタルワーカー | BullX AI 同僚 |
| --- | --- | --- | --- |
| コア単位 | Agentic Loop または assistant session。 | App、Bot、RPA flow、または Workflow run。 | 長期 mission・責任・Work/MailBox ルーティング文脈を持つ Agent。 |
| 自律性 | prompt、メッセージ、cron、ユーザー設定タスクに応答。 | 特定業務シナリオの既定フローを実行。 | Event を観測し、優先順位を付け、支援要請し、委譲し、長期 mission を前進。 |
| 行動 | Tool call、shell/browser 操作、メッセージ、ファイル、SubAgent。 | フォーム入力、API 呼び出し、抽出、ルーティング、承認、レポート生成。 | ガバナンスされた Capability、AIAgent 行動、必要時の Workflow step。 |
| 記憶と推論 | Session memory、Markdown ファイル、skill notes、外部 memory layer。 | RAG ナレッジベース、workflow 変数、app 固有 state。 | Brain は会話・イベント・行動・関係・結果・domain object から成長する推論世界モデル。 |
| 自己進化 | 過去 session から新しい skill や notes を学習。 | workflow やナレッジベースの手動更新に依存。 | 軌跡データで planning・Skill・policy・将来実行を改善。 |
| 権限と予算 | 主に tool policy、model 設定、ローカル runtime 制御。 | app credential、node 権限、レート制限、workflow 設定。 | Principal ID、委任権限、Budget、外向き ID、監査境界。 |
| 人間協働 | approval prompt、DM gate、手動確認が一般的。 | フロー内の approval node や人手レビュー。 | 人間は上位・同位・下位として協働可能：承認、是正、エスカレーション、引き継ぎ、文脈補完、現実世界タスク支援、Agent からのタスク受領。 |
| 外部イベント | channel、cron、webhook、integration が assistant loop に入力。 | trigger で定義済み app / workflow を起動。 | Gateway が外部事実を保持し、MailBox が CloudEvents mail を配送し、Receiver が業務記録で長期 Work を更新。 |
| 説明責任 | Transcript と tool 履歴で 1 session を説明。 | Workflow log で 1 app run を説明。 | 誰が行動し、誰が承認し、予算をどれだけ使い、何が変化し、軌跡データで将来行動がどう改善したかを product fact として記録。 |

## なぜ BullX か

BullX は、前世代 agent システムの有用な表面（channel、tool、Skill、sandbox、browser、SubAgent、schedule、会話入口）を保持します。違いは product fact の帰属先です。BullX では持続的な仕事は、単発 assistant session や workflow run log だけでなく、Work、Conversation、ApprovalRequest、ChildRun、Principal、Budget、Brain、domain record、軌跡データといった業務記録に帰属します。

BullX は Palantir 型 ontology エンジニアリングとも異なります。Brain は ontology や semantic web の発想に影響を受けていますが、最初に完全な業務グラフを専門家が定義することを要求しません。世界モデルは仕事の中で自然に成長すべきです。会話、Event、domain record、意思決定、引き継ぎ、是正、結果が、AI 同僚に業務・業界・社内文脈・暗黙知を段階的に教えます。

BullX が目指すのは「より良い bot」や「より賢い workflow app」ではなく、AI 同僚が観測・判断・委譲・待機・要請・支出・記憶・行動し、その全体がプロダクト層で追跡可能な OS です。

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

## 期待する体験

**グループチャットは割り込まずに傍受できる。** カスタマーサクセス Agent はグループチャットからリスクを検知し、Work を作成し、公開チャンネルではなく担当者へ私的に通知できます。

**1 つの入力を正しい実行経路へ流せる。** 顧客の予算凍結メッセージは gateway に保存され、MailBox で配送され、Receiver に到達します。Receiver はケースを直接処理する AIAgent でも、明示的分岐・承認・並列・決定的ステップを表現する Workflow でもかまいません。

**記憶は会話ログだけでなく世界を含める。** リサーチ Agent は会話を市場・政策・プロダクト・運用・外部イベントと合わせて理解し、実務から成長した ontology-backed world model で文脈を取得すべきです。

**世界モデルは人間同僚のように成熟できる。** BullX Agent はオンボーディング後、業務・業界・社内ルール・繰り返し現れる例外・暗黙知に徐々に習熟すべきであり、day one ですべてを組織側がモデリングし切る必要はありません。

**Agent は単発タスクではなく長期 mission を持てる。** Coding Agent、リサーチ Agent、カスタマーサクセス Agent は、複数のやり取りをまたいで継続的に働き、人間や他 Agent と協働し、軌跡データから次の planning を改善できます。

**人間は Agent の上位・同位・下位として協働できる。** 人間は承認・是正だけでなく、同位として推進し、特定ケースを引き継ぎ、現実世界情報を補い、さらには Agent からタスク（例: オフライン確認、サイトの QR ログイン補助）を受けることもできます。

**高リスク業務は明示的にゲートできる。** 顧客対応、金融、法務、権限変更、不可逆な外部操作は、副作用を発生させる前に approval または policy gate を通すべきです。
