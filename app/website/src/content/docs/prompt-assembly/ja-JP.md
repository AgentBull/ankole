---
title: プロンプト組み立て
section: Developer guide
order: 118
description: メイン Agent のシステム指示と Codex Job のコンテキストを組み立てる処理経路を説明します。
---

メイン Agent に渡すモデル指示（システムプロンプト）は、コントロールプレーン側で組み立てられます。具体的には、`Ankole.Sessions.Context.resolve/2` が最新のドメイン情報を読み込み、`Ankole.Sessions.Prompt.system/1` がテンプレートを描画したうえで、`Ankole.Sessions.Driver` が AIGateway 経由でモデルへ送信します。一方、Worker 側は環境ツールの操作と Codex Job の実行を受け持ちます。全体像については [Agent loop](../agent-loop/) を参照してください。

## 現在のコンテキスト

解決されるコンテキストには、Agent の識別情報と定義ドキュメント、有効な Skill とプラグイン、会話の開始チャネル、およびタイムゾーンが含まれます。`SOUL.md` は行動指針と判断基準を、`MISSION.md` は担当業務の責務を定義するもので、それぞれのドメイン所有者が PostgreSQL に永続化しています。環境ツールを使う際には、ワークスペース契約にもとづいて実体化されたランタイムファイルが渡されます。

メインのシステムプロンプトは、識別情報、SOUL、MISSION、完了条件と権限に関する指示、利用可能な Job と Workflow の方針、記憶（メモリ）、環境およびツールの説明、Skill カタログ、ランタイムコンテキストの順に構成されます。テンプレート群は `app/control_plane/priv/sessions/prompts/` に置かれており、描画ロジックは `app/control_plane/lib/ankole/sessions/prompt.ex` に実装されています。

`brain-recall-only: true` が指定された Skill はプロンプト内のカタログ一覧からは省略されますが、有効な Skill セットには含まれているため、Brain 検索で見つけて `skill_view` から読み込むことができます。プロンプト末尾には、対象の Agent 名、`/workspace`、現在の Session ワークスペースパス、タイムゾーン、会話の開始時刻と開始チャネルが付記されます。なお、Lark アダプターは Lark と Feishu の双方に対応しており、ドメイン層が適切な上流 API を選択します。

## 設定と履歴

テナント単位の実行パラメータは `AgentConfig` で解決されます。既定値は、`ai_agent.max_iterations` が `90`、`ai_agent.max_output_tokens` が明示的上限なし、`ai_agent.inactivity_timeout_ms` が `30 分` となっており、これらがコントロールプレーン上の各 Turn の上限を制御します。

会話履歴と監査用のリクエスト記録は AIGateway が保存します。今回の入力イベントや Provider 側の観測情報は `Prompt.Input` によってユーザーメッセージとして整形されるため、システムプロンプト側に重複して埋め込まれることはありません。コントロールプレーンは Run のたびに最新のドメイン状態からプロンプトを再描画します。

## Codex Job と Workflow タスク

Codex Job は独立した Worker 実行経路を通ります。Runner が固定された実行設定を解決し、RPC 経由で最新のドメイン情報を取得して Job プロジェクトと `AGENTS.md` を準備したうえで、ネイティブの Codex が Job 内のモデルループを駆動します。詳しくは [Background Agent Jobs](../background-agent-jobs/) を参照してください。

Workflow タスクでは、`Prompt.workflow_system/1` を通じて識別情報、タスク ID、保存済みの結果スキーマ、提出方法、委譲およびスリープの規則が渡されます。また、Ambient ルーティングにも専用のプロンプトが用意されており、それぞれの経路が固有の実行契約に従って動作します。
