---
title: プロンプト組み立て
section: Developer guide
order: 118
description: メイン Agent の指示と Codex Job のコンテキストを組み立てる経路。
---

コントロールプレーンがメイン Agent のモデル指示を組み立てます。`Ankole.Sessions.Context.resolve/2` が現在のドメイン情報を読み、`Ankole.Sessions.Prompt.system/1` が描画し、`Ankole.Sessions.Driver` が AIGateway 経由で送ります。Worker は環境操作と Codex Job を受け取ります。[Agent loop](../agent-loop/) を参照してください。

## 現在のコンテキスト

Agent の識別情報と文書、有効な Skill とプラグイン、会話の開始チャネルとタイムゾーンが含まれます。`SOUL.md` は行動と判断、`MISSION.md` は責任を示します。ドメイン所有者が PostgreSQL に保存します。環境ツールは workspace 契約で実体化されたランタイムファイルを受け取ります。

メインプロンプトは識別情報、SOUL、MISSION、完了と権限の指示、利用可能な Job と Workflow の方針、記憶、環境とツールの指示、Skill カタログ、ランタイムコンテキストの順です。テンプレートは `app/control_plane/priv/sessions/prompts/`、描画処理は `app/control_plane/lib/ankole/sessions/prompt.ex` にあります。

`brain-recall-only: true` の Skill はカタログから省略しますが、有効セットに残り、Brain で発見して `skill_view` で読み込めます。末尾には Agent、`/workspace`、現在の Session workspace、タイムゾーン、会話開始時刻と開始チャネルを記載します。Lark adapter は Lark と Feishu を表し、domain が上流 API を選びます。

## 設定と履歴

`AgentConfig` はテナント設定を解決します。`ai_agent.max_iterations` は 90、`ai_agent.max_output_tokens` は明示的上限なし、`ai_agent.inactivity_timeout_ms` は 30 分が既定値です。これらはコントロールプレーンの Turn を制限します。

AIGateway が会話履歴と監査用リクエストを保存します。現在の入力と provider の観測は `Prompt.Input` で user message にし、system 指示に重複しません。コントロールプレーンは Run ごとに現在の情報から描画します。

## Codex Job と Workflow タスク

Codex Job は独立した Worker 経路です。Runner は固定された実行選択を解決し、RPC で現在のドメイン情報を取得して Job project と `AGENTS.md` を準備します。Native Codex が Job のモデルループを所有します。[Background Agent Jobs](../background-agent-jobs/) を参照してください。

Workflow タスクは `Prompt.workflow_system/1` で識別情報、タスク ID、保存済み結果 schema、提出、委譲と sleep の規則を受け取ります。Ambient routing にも専用プロンプトがあります。各経路はそれぞれの実行契約に従います。
