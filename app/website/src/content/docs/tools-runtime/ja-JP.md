---
title: Tool ランタイム
description: コントロールプレーンにおけるツール宣言の組み立てと、Worker での環境ツール実行の仕組みを説明します。
section: Developer guide
order: 120
---

メイン Agent のモデルループとツールディスパッチはコントロールプレーンが所有します。`Ankole.Sessions.Driver` が AIGateway を呼び出し、モデルから要求されたツールを実行し、その結果を記録して次のイテレーションへ Turn を進めます。一方、Agent Computer は環境ワークスペース上の操作と Codex Job の実行を担当します。全体像については [Agent loop](../agent-loop/) および [Agent Computer Worker](../agent-computer-worker/) を参照してください。

## 現在のツールセット

各 Run で利用可能なツール一覧は、`Ankole.Sessions.ToolCatalog.for_run/1` がコントロールプレーン側のドメイン宣言と `worker_tools.json` の Worker 側宣言を組み合わせて動的に構築します。Agent ごとに固定のグローバルツールセットを保存するのではなく、Run の種別、選択モデルの対応機能、有効な Skill とプラグイン、および ambient 権限にもとづいてその都度決定します。

各ツールの定義構造体である `Ankole.Sessions.Tool` は、モデルに提示する JSON Schema、実行主体、実行順序（並列可否）、許可される呼び出し元、および読み取り専用・破壊的操作・再試行可否を表すメタデータを保持します。実行前には `Ankole.Sessions.Tools.prepare/2` が呼び出し元の権限を確認し、引数をパースして所有モジュールで正規化したうえで、JSON Schema による検証を通過してからディスパッチします。

## 所有者での実行

ツールの種類ごとに、実際の処理を担う実行主体が分かれています。

- **コントロールプレーンのドメインツール：** Session 内の計画管理、スケジュール、Background Agent Job、Workflow、Skill の読み取り、およびドメイン層の Web 操作は、コントロールプレーン内の各所有モジュールが直接実行します。
- **Worker の環境ツール：** ファイルやシェルなどの計算機操作は RuntimeFabric 経由でその Agent 専用の Worker へ委譲されます。最初の環境ツール呼び出しが行われた時点で Session ワークスペースが開かれます。実行スロットとプロセス状態は Worker 側が管理し、永続化すべき実行結果はコントロールプレーン側が管理します。
- **MCP 連携 Skill：** Worker の `command` ツールと `mcporter` を組み合わせて実行します。
- **Provider ホスト型ツール：** 選択したモデルが宣言している機能に従い、AIGateway 経由で実行します。

Driver は各ツールの宣言に従い、並列または順次でツールを実行します。永続状態を伴う変更では `Ankole.Sessions.Receipts` を用い、ドメインデータの更新とツール実行結果を単一のトランザクションでコミットします。出力内容は次のモデル推論ラウンドで使えるよう AIGateway に保存されます。また、実行途中に Worker との接続が切れた場合、結果が確定していない環境操作については、各ツールで宣言された再試行契約に従って Driver が処理します。

## Workflow タスク

Workflow タスクに提供されるツールカタログは、Web 操作、委譲および状態確認のための Background Agent Job 操作、`sleep`、そして `submit_result` のみに絞られます。また、ホスト型の Brain ツールも `recall` と `get_page` だけに限定され、計算機操作、シェル、Skill、スケジュール、新規 Workflow 作成のツールは公開されません。

`submit_result` が呼ばれると、保存済みの結果スキーマに対して出力が検証されます。検証に通らなければエラーが返されてモデルが修正でき、受理された時点でタスク完了となります。なお、結果を提出する前に、委譲中の Background Agent Job をすべて終了させておく必要があります。詳しくは [Workflow](../workflows/) を参照してください。

## ツールの追加

新しいドメインツールを追加する場合は、コントロールプレーンの所有ドメイン内に宣言と実装の両方を配置します。新しい環境ツールを追加する場合は、Worker 側に実装を追加したうえで `worker_tools.json` を再生成します。Worker ツールの実装契約は `WorkerAgentTool` と Zod スキーマで定義されており、公開スキーマと実際の実行境界が常に一致するよう保つ必要があります。
