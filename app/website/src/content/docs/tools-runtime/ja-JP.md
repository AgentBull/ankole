---
title: Tool ランタイム
description: コントロールプレーンのツール宣言と Worker の環境実行。
section: Developer guide
order: 120
---

コントロールプレーンはメイン Agent のモデルループとツール分配を所有します。`Ankole.Sessions.Driver` は AIGateway を呼び、要求されたツールを実行し、結果を記録して Turn を続けます。Agent Computer は環境操作と Codex Job を実行します。[Agent loop](../agent-loop/) と [Agent Computer Worker](../agent-computer-worker/) を参照してください。

## 現在のツールセット

`Ankole.Sessions.ToolCatalog.for_run/1` は現在のドメイン宣言と `worker_tools.json` の Worker 宣言を組み合わせます。Run の種類、モデルの能力、選択された Skill とプラグイン、ambient 権限に従って構築し、Agent のグローバルなツールセットとして保存しません。

`Ankole.Sessions.Tool` はモデル向け schema、実行主体、実行順序、許可する呼び出し元、読み取り・破壊・再試行のメタデータを保持します。`Ankole.Sessions.Tools.prepare/2` は呼び出し元を確認し、引数を解析して所有者に正規化させ、JSON Schema を検証してから実行します。

## 所有者での実行

- Session の計画、スケジュール、Background Agent Job、Workflow、Skill の読み取り、ドメインの Web 操作はコントロールプレーンの所有者が実行します。
- Computer 操作は RuntimeFabric 経由で Agent の Worker に委譲します。最初の環境操作が Session workspace を開きます。Worker は slot とプロセス状態、コントロールプレーンは永続的な結果を所有します。
- MCP-backed Skill は Worker の computer command と mcporter を使います。
- Provider の hosted tool は AIGateway 経由で実行し、選択モデルの宣言された能力に従います。

Driver は宣言に従って並列または順次実行します。永続的な変更は `Ankole.Sessions.Receipts` を使い、ドメイン変更と結果を同じトランザクションでコミットします。AIGateway は次のモデル反復用に出力を保存します。Worker 切断時は、Driver が宣言された再試行契約に従って結果不明の環境操作を処理します。

## Workflow タスク

カタログは Web 操作、委譲と確認用の Background Agent Job 操作、`sleep`、`submit_result` に限定されます。Hosted Brain は `recall` と `get_page` のみです。Computer、shell、Skill、スケジュール、Workflow 作成のツールは提供しません。

`submit_result` は保存済み結果 schema で検証します。拒否時は修正でき、受理時はタスクが終了します。提出前に実行中の委譲 Job を終了させる必要があります。[Workflow](../workflows/) を参照してください。

## ツールの追加

ドメインツールはコントロールプレーンの所有者に宣言と実装を置きます。環境ツールは Worker に追加して `worker_tools.json` を再生成します。`WorkerAgentTool` と Zod は Worker の実装契約であり、メインモデルループの所有者ではありません。Schema と実行境界を一致させてください。
