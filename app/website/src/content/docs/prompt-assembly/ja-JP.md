---
title: プロンプト組み立て
description: agent が毎ターン見るシステムプロンプトがどう構築されるか — コントロールプレーンのデータ provider、それを worker に運ぶ 2 つの channel、最終プロンプトを生成する worker 側の組み立て。
section: Developer guide
order: 118
---

毎ターン、worker はモデルが見るシステムプロンプトを構築します。そのプロンプトは PostgreSQL が支える agent コンテキストから組み立てられ、ターン時に解決され、worker 上で描画されます。このページは、部品がコントロールプレーンから worker にどう届くか、各部品が何か、組み立てがどこで行われるかを説明します。[Agent Computer Worker](../agent-computer-worker/) と [AIGateway](../ai-gateway/) ページの上に構築されます。

システムプロンプトはコントロールプレーンではなく**Worker 上で組み立て**られます。コントロールプレーンは永続的な Agent ドキュメント、Skill、Agent 設定、チャットコンテキストを 2 つの経路で供給します。Worker がこれらの事実を最終プロンプトに描画します。

## 2 つのデータ channel

worker はコントロールプレーンから 2 つの経路でコンテキストを受け取ります。各経路は異なるクラスのデータを運びます:

| channel | 運ぶもの | タイミング |
|---|---|---|
| `turn_start.request_context` | agent-loop 設定（`ai_agent.max_iterations`、`max_output_tokens`、`inactivity_timeout_ms`）とターンローカルな事実（シグナルとターンの種類） | ループ開始前の TurnStart エンベロープに埋め込まれる |
| `AgentConversationContextBroker` RPC | 永続的な Agent ドキュメント（`SOUL`/`MISSION`/`DESIGN`）、有効な Skill、会話の発信 channel、インスタンスタイムゾーン、agent プロファイル | ループ開始時に worker が RuntimeFabric 上の RPC を通じて取得 |

この分割は意図的です。ターンローカルな事実は毎ターン変わるため `turn_start` で運ばれます。会話スコープのコンテキストは会話内のターン間で安定しており、ブローカーがキャッシュするため、worker がブローカーを通じて取得します。ブローカーのモジュール doc は明示的です:「この RPC は意図的にトランスクリプトメッセージやターンローカルなリクエストコンテキストを返しません。トランスクリプト履歴は AIGateway が所有し、ターンローカルな事実は `turn_start` で運ばれます。」

## コントロールプレーンが提供するもの

### 永続的な Agent ドキュメント

`AgentConversationContextBroker` は `Library.list_agent_documents/1` を通じて Agent の永続的なドキュメントを読み取ります。それらを `soul`、`mission`、`design` として返します。`SOUL.md` はコミュニケーションと判断を定義し、`MISSION.md` は責任を定義し、`DESIGN.md` は視覚的な作業のためのデザインシステムを提供します。

### 有効な Skill

`Library.runtime_skills_for_agent/1` は、説明とメタデータを含む Agent の完全な有効 Skill セットを Worker に送ります。Worker は完全なセットを `skill_view` 用に保持します。モデルに見える Skill カタログを構築するときは、`brain-recall-only: true` を宣言した Skill を除外します。これにより、すべてのプロンプトに表示せずに Brain からその Skill を発見できます。

### 会話の発信 channel

`SignalsGateway.ConversationChannel` は AIGateway の会話が宣言する provider channel をプロジェクションします。現在の channel ミラーからグループラベルを、ピア Principal から DM ラベルを読み取ります。`lark` adapter を 1 つの Lark / Feishu サーフェスとして報告します。adapter ドメインは API サーバーを選択するだけです。ブローカーはこのプロジェクションを `ConversationInfo.origin_channel` で送るため、ActorEvent ペイロードに channel オブジェクトがなくても、内部起床が会話の発信を失いません。

### Agent 設定（AppConfigure から）

`AgentConfig` はループレベルの設定を AppConfigure から解決し、`turn_start.request_context.ai_agent` にスナップショットします:

- `ai_agent.max_iterations`（既定 90）— agent ループの反復予算
- `ai_agent.max_output_tokens`（既定 nil = 明示的な上限なし）— 応答ごとの token 上限
- `ai_agent.inactivity_timeout_ms`（既定 30 分）— ターンが非アクティブでいられる時間

これらは個々のモデル応答ではなく actor ターンに属するため、`turn_start` に乗ります。

## worker 側の組み立て

worker の `system_prompt.ts` が最終プロンプトを構築します。そのモジュール doc は設計を述べています:「ゆっくり変わる指示を先頭に置き、会話スコープのランタイムと Skill のコンテキストをサフィックスとして形成する。」ブロックは順に:

1. **コア指示** — agent の基本挙動コントラクト。ターンのコンテキストから組み立てられます。
2. **永続的な Agent ドキュメント** — `SOUL`、`MISSION`、`DESIGN`。ブローカーの応答から描画されます。
3. **Skill** — 有効な Skill の説明。モデルが何に手を伸ばせるかを伝えます。
4. **channel とランタイムコンテキスト** — 会話の発信 channel、ワークスペースパス、利用可能なツール名。

worker は毎ターン、現在の PostgreSQL が支えるコンテキストから完全なプロンプトを再描画します。キャッシュされたバージョンを信頼しません。AIGateway は監査のために以前のリクエスト指示を保持しますが、ターンは現在の状態を描画します。

## システムプロンプトに含まれないもの

- **トランスクリプト履歴** — AIGateway のステートフル Responses が所有します。システムプロンプトはそれを繰り返しません。
- **ターンローカルな観察** — シグナル、受信メッセージ、ユーザーの現在の入力。これらはシステムプロンプトではなく現在のユーザーメッセージに残ります。

この分離により、システムプロンプトは安定し（ペルソナや Skill が変わるときにだけ変わり、会話が長くなっても変わりません）、ターンごとのペイロードは小さく保たれます。

## このガイドがそうでないもの

プロンプトエンジニアリングのチュートリアルではありません。`system_prompt.ts` の文字列リテラルはモデルとのコントラクトであり、それを変えることはドキュメントの変更ではなく挙動の変更です。コントロールプレーン側のプロンプト組み立ての説明でもありません。組み立ては worker 側にあり、コントロールプレーンの役割はデータの提供です。そして `system_prompt.ts` を読むことの代わりでもありません。これはその地図です。

## 次のステップ

- このプロンプトを使う agent ループについては、[The agent loop](../agent-loop/) を読んでください。
- 組み立てを実行する Agent Computer Worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
- Skill ブロックについては、[Agent Library](../agent-library/) を読んでください。
