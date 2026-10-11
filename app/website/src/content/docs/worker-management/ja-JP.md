---
title: Worker
description: Console で各 Agent の Worker を確認し、control plane による管理方法を理解し、よくある障害を解決する。
section: User guide
order: 52
---

各 Agent は専用 Worker と `/workspace` の永続 Home を持ちます。Console で Worker provider の種類、YAML 設定、別途保存する認証情報を指定します。Agent 作成時に provider を選び、その後は変更できません。異なるインスタンス仕様には別の provider を作成します。

## Worker pool

1 つの Worker provider が 1 つの Worker pool を定義します。pool はプラットフォームの種類、YAML 設定、別途暗号化した認証情報を持ち、site に属します。異なる tenant の Agent が同じ pool を選べますが、各 Agent は専用 Worker、永続 Home、キャッシュ、Worker 認証情報を保持します。

1. **Console → Settings → Worker providers** で **New Worker provider** を選びます。
2. 種類を選び、YAML の例からイメージ、インスタンス仕様、ストレージ、接続先を設定します。
3. 別の認証情報フィールドにプラットフォームのキーを入力し、保存後に接続確認を実行します。
4. 1 つの pool を既定にするか、Agent 作成時に pool を選びます。どちらも指定されない場合、Agent 作成は失敗します。

site の既定 pool は最大 1 つです。既定の変更は後から作成する Agent にだけ適用され、既存 Agent は元の provider を保持します。仕様や場所が異なる場合は別の pool を作成します。同じ種類の pool も複数作成できます。作成後は provider ID、種類、ストレージの場所、Agent の provider 選択を変更できません。Agent Worker 行が参照する pool は削除できません。

pool は選択したプラットフォームでインスタンスを管理し、ある Agent のコンピュータを別の Agent に割り当てません。作成は [Agents](../agents/)、実行と復旧は [Agent Computer Worker](../agent-computer-worker/) を参照してください。

## Agent ごとに 1 台の Worker

Agent 作成時は provider の選択と Worker 行を保存し、インスタンスは起動しません。環境ツール、Codex Job、Automation Job が必要になった時点で control plane が Worker を起動します。主会話と Workflow のモデル呼び出しは control plane で実行し、Worker なしでも進められます。

同じ Agent の Session と Job は Home 内の別々の workspace を使い、コンピュータと Home を共有します。開いている環境 workspace と実行中の Codex turn はそれぞれ Worker slot を 1 つ使います。`ANKOLE_MAX_CONCURRENT_SLOTS` はその Worker の容量を設定します。pool や別の Agent を追加しても、既存 Agent の Worker slot や、別途設定する Background Agent Job の同時実行上限は増えません。

## Worker を表示する

**Console → Workers** で Agent、provider、状態、負荷、heartbeat、最新のプラットフォームエラーを確認します。

| 状態 | 意味 |
| --- | --- |
| `absent` | インスタンスなし。必要時に作成 |
| `starting` | generation を保存済み。作成または接続承認を待機 |
| `ready` | 接続済みで Turn を実行可能 |
| `stale` | 以前の接続が切断 |
| `paused` | プロセスとメモリを保持して休止 |
| `draining` | 解放または置換を待機 |
| `deleting` | インスタンスとストレージの削除を待機 |

作成がタイムアウトした場合は同じ generation で再試行します。結果が不明なら待機を続け、書き込み元が二重になるインスタンスは作成しません。設定変更の前に **Reason** を確認してください。

## Provider とストレージ

| 種類 | 永続 Home | アイドル時 |
| --- | --- | --- |
| Docker | Agent ごとのローカル volume | コンテナ削除 |
| Kubernetes | 専用 PVC または共有 PVC 内のディレクトリ | Pod 削除 |
| Cloudflare | R2 ディレクトリバックアップ | バックアップ後に削除 |
| Vercel | Agent ごとの Drive | sandbox 削除 |
| Lambda MicroVMs | EFS の Agent ディレクトリ | メモリを保持して休止 |
| Function Compute | Agent ごとの AgenticSpace または OSS prefix | メモリを保持して休止 |

Vercel の 24 時間セッションには Pro または Enterprise が必要です。Lambda のメモリクォータは、実行中と休止中の Worker に加えて、ストレージ削除用インスタンスの分も確保してください。デプロイ前に、リポジトリの CONTRIBUTING のコマンドで対象環境を検証してください。Function Compute は公式プロトコルに従います。ストレージ、テンプレートの保存とメモリ休止は有効な Aliyun アカウントでの検証が必要です。ACS は既定のメモリ保持が未確認のため未登録です。

Home はインスタンス削除やイメージ変更後も残ります。Codex スレッドは `/workspace/.codex`、SQLite キャッシュは `/var/cache/ankole/codex` にあります。再構築ではキャッシュだけを削除します。Docker のローカル volume はホスト消失に耐えません。Cloudflare の強制停止では最終バックアップ後の書き込みを失う場合があります。Home と [Agent ドライブ](../file-management/) の両方をバックアップしてください。

## 解放、置換、削除

- provider YAML の `idleReleaseAfter` を設定します。Docker と Kubernetes の既定値は `never`、Cloudflare、Vercel、Lambda、Function Compute は `15m` です。
- メモリ休止対応の provider はアイドル Worker を休止します。他の種類はインスタンスを削除し、永続ストレージと設定済みキャッシュ volume を残します。
- イメージやインスタンス設定の変更はアイドル時に置換します。プロトコル変更は即時置換です。古い休止インスタンスは作業再開前に置換します。
- `agent_computer.worker.ready_timeout` の既定値は 600 秒です。既に観測したインスタンスだけを再構築し、結果不明の作成を終了扱いにはしません。
- Agent 削除では、全インスタンスの消失後に Home とキャッシュを削除し、最後に Worker 行を削除します。Agent UID はサーバーが生成し、再利用しません。

## 未準備の Worker を調べる

provider の認証情報、ストレージ、容量、`endpoints` を確認します。Docker は `ANKOLE_DOCKER_GID`、Kubernetes は Role、Pod イベントと PVC、Cloudflare はイメージ設定と token、Lambda はビルド状態、ビルドロール、VPC connector、EFS 接続を調べます。

provider ラベルで対象を確認し、停止前にログを読みます。Kubernetes は通常の削除完了を待ち、ノード障害を grace 0 で回避しないでください。Docker は停止してから削除します。

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

必要時に control plane が新しいインスタンスを作成します。Home とキャッシュ volume は残ります。実行中の Turn は中断され、各再試行規則に従います。ready でも待機する場合は負荷と Turn 容量を比較してください。`ANKOLE_MAX_CONCURRENT_SLOTS` は provider YAML の環境設定で、変更後はアイドル時に置換します。[性能調整](../performance-tuning/)を参照してください。
