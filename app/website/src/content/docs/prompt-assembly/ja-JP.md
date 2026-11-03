---
title: プロンプト組み立て
section: Developer guide
order: 118
description: メイン Agent のシステム指示と Codex Job のコンテキストを組み立てる処理経路を説明します。
---

メイン Agent に渡すモデル指示（システムプロンプト）は、コントロールプレーン側で組み立てられます。具体的には、`Ankole.Sessions.Context.resolve/2` が最新のドメイン情報を読み込み、`Ankole.Sessions.Prompt.system/1` がテンプレートを描画したうえで、`Ankole.Sessions.Driver` が AIGateway 経由でモデルへ送信します。一方、Worker 側は環境ツールの操作と Codex Job の実行を受け持ちます。全体像については [Agent loop](../agent-loop/) を参照してください。

## 現在のコンテキスト

各 Run は Agent の識別情報、有効な能力、開始元の会話、タイムゾーンを解決します。`Ankole.AIAgent.Library.Contracts` は個別の継承・追加・上書き設定に従って全体の基準を合成します。コントロールプレーンは有効な `AGENTS.md` を全文読み込みます。`DESIGN.md` も同じモジュールが管理し、完全なランタイムファイルとして提供します。

`Ankole.Sessions.Prompt.system/1` は AGENTS 規約の全文、完了と権限の規則、Job と Workflow の方針、記憶の指針、環境とツールの説明、Skill カタログ、実行時コンテキストを順に組み立てます。テンプレートは `app/control_plane/priv/sessions/prompts/` にあります。

Skill カタログには、その Agent が有効にしているパッケージの説明を載せます。`skill_view` は選択したマニフェストを必要に応じて読み、Agent は参照先のファイルを明示的に読み込みます。末尾には Agent、`/workspace`、Session ワークスペース、タイムゾーン、会話の開始時刻とチャネルを記録します。Lark と Feishu は共通のアダプターを使い、設定されたドメインによって上流 API を選びます。

## 設定と履歴

テナント単位の実行パラメータは `AgentConfig` で解決されます。既定値は、`ai_agent.max_iterations` が `90`、`ai_agent.max_output_tokens` が明示的上限なし、`ai_agent.inactivity_timeout_ms` が `30 分` となっており、これらがコントロールプレーン上の各 Turn の上限を制御します。

会話履歴と監査用のリクエスト記録は AIGateway が保存します。今回の入力イベントや Provider 側の観測情報は `Prompt.Input` によってユーザーメッセージとして整形されるため、システムプロンプト側に重複して埋め込まれることはありません。コントロールプレーンは Run のたびに最新のドメイン状態からプロンプトを再描画します。

## Codex Job と Workflow タスク

Codex Job は Worker が実行します。各 Turn の開始時と再開時に最新の規約を取得し、`$CODEX_HOME/AGENTS.md`、`~/AGENTS.md`、`~/DESIGN.md` をアトミックに更新します。ネイティブ Codex は全体の Agent 指示とプロジェクト固有の指示ファイルを組み合わせます。詳しくは [Background Agent Jobs](../background-agent-jobs/) を参照してください。

Workflow タスクでは、`Prompt.workflow_system/1` を通じて識別情報、タスク ID、保存済みの結果スキーマ、提出方法、委譲およびスリープの規則が渡されます。また、Ambient ルーティングにも専用のプロンプトが用意されており、それぞれの経路が固有の実行契約に従って動作します。
