---
title: パフォーマンスチューニング
description: Worker slot、モデル並行数、DB pool、Job 上限、idle 回収。
section: Guides
order: 319
---

主会話と Workflow のモデル呼び出しは control plane で実行します。質問だけでは Worker を起動しません。Worker 容量は開いている環境 workspace と実行中の Codex turn を数えます。slot 数は全会話の並行上限ではありません。

## 容量の owner

Driver はモデルやツールを待つ間、DB 接続を解放します。モデル並行数、provider quota、Worker slot、DB query 並行数は別の制限です。全 control plane replica の pool 合計を Postgres 接続予算以下にし、管理と他サービス用の接続も確保します。pool checkout の待機を測定してから調整します。

| ノブ | 既定 | 上限の対象 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | デプロイ seedでは 12（未設定時は 9） | 1 Agent の open 環境 workspace と running Codex turn |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | コントロールプレーンのデータベース接続プール |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres の `max_connections`（バンドルサーバー） |
| `max_running_per_agent` | 3 | agent ごとの実行中Background Agent Jobの最大数 |
| `idleReleaseAfter` | Docker / Kubernetes: `never`; Cloudflare / Vercel / Lambda / Function Compute: `15m` | Worker が停止して CPU とメモリを解放するまでのアイドル時間 |

## 待機している境界を調整する

- provider 容量を待つモデル要求は provider quota と credential を確認します。
- `no_worker_capacity` を待つ環境ツールには空き slot が必要です。上限を上げる前に保留 workspace の実行中コマンドを確認します。
- queued Background Job は Agent の Job 上限または Worker 容量を待つことがあります。Worker slot を増やしても Job 上限は変わりません。
- DB checkout 遅延は全 replica の pool と Postgres 容量を確認します。

provider YAML の変更は idle Worker の置換時に適用します。既存 generation は保存された設定を保持します。`idleReleaseAfter` は idle resource を解放し、永続 Home は provider storage に残ります。

[Workers](../worker-management/)、[Background Jobs](../background-agent-jobs/)、[cost management](../cost-management/) も参照してください。
