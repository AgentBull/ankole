---
title: パフォーマンスチューニング
description: Worker スロット、モデル同時実行数、DB コネクションプール、Job 上限、アイドル回収の調整方法を説明します。
section: Guides
order: 319
---

メイン会話および Workflow のモデル呼び出しはコントロールプレーン上で実行されるため、質問への応答だけで Worker が起動することはありません。Worker の容量（スロット）として消費されるのは、開いている環境ワークスペースと実行中の Codex Turn のみであり、スロット数がそのまま会話全体の同時実行上限になるわけではありません。

## 容量の owner

セッション Driver はモデル応答やツール実行を待機している間、DB コネクションを手放します。モデルの同時実行数、Provider のクォータ、Worker スロット数、DB クエリの同時実行数はそれぞれ独立した制限として機能します。

すべてのコントロールプレーンレプリカにわたる `Ankole.Repo` と `Ankole.Pod.BaseRepo` の接続プール合計が、各 PostgreSQL サーバーの接続上限（`max_connections`）内に収まるよう設計し、管理操作やメンテナンス用の接続枠も余分に確保してください。`BASE_DB_URLS` を設定しない単一データベース構成では、`Ankole.Pod.BaseRepo` が `Ankole.Repo` の 10 接続プールとは別に `DATABASE_URL` に対して 10 接続のプールを開くため、1 レプリカあたり合計 `20` 接続を消費します。一方、`BASE_DB_URLS` で専用のシャードデータベースを指定する場合は、各シャードサーバーの `max_connections` を `レプリカ数 × ankole_pool_size` に見合う値に設定してください。プールサイズを変更する際は、事前にプールチェックアウトの待ち時間を計測してから調整することをおすすめします。

| ノブ | 既定 | 上限の対象 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | デプロイ seed では 12（未設定時は 9） | 1 Agent あたりの開いている環境ワークスペースと実行中の Codex Turn の合計 |
| `POOL_SIZE`（Compose/Helm では `ANKOLE_DATABASE_POOL_SIZE`） | 10 | レプリカごとの `Ankole.Repo` コントロールプレーン DB 接続プール |
| `BASE_DB_URLS`（`ankole_pool_size`） | シャードごとに 10（dev/test では `2`） | レプリカごとの各 `Ankole.Pod.BaseRepo` Base シャード接続プール |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres の `max_connections`（同梱サーバー利用時） |
| `agent_computer.background_agent_job.max_running_per_agent` | 3 | Agent ごとの実行中 Background Agent Job の最大数（テナントスコープ） |
| `idleReleaseAfter` | 全 6 プロバイダー共通で `15m`（`never` でアイドル停止を無効化） | Worker が停止して CPU とメモリを解放するまでのアイドル時間 |

## 待機している境界を調整する

どのリソース境界で待ちが発生しているかに応じて、確認・調整する対象が異なります。

- **Provider の容量待ちになっているモデルリクエスト：** Provider 側のクォータ上限と認証情報の状態を確認します。
- **`no_worker_capacity` で待機している環境ツール：** Worker の空きスロットが必要です。上限値を引き上げる前に、保留中のワークスペースで実行されたままになっているコマンドがないか確認してください。
- **キューに入ったままの Background Job：** Agent ごとの Job 同時実行上限、または Worker 容量の空きを待っている可能性があります。Worker スロットを増やしても Job の同時実行上限自体は変わらない点に注意してください。
- **DB チェックアウトの遅延：** 全レプリカおよび Base シャードにわたる `Ankole.Repo`・`Ankole.Pod.BaseRepo` のプールサイズと、PostgreSQL 側の接続容量を確認します。

Provider YAML の設定変更は、アイドル状態の Worker が入れ替わる際に適用され、稼働中の世代（generation）は保存済みの設定を維持したまま動作します。また、`idleReleaseAfter` の経過によってアイドル状態の計算リソースは解放されますが、永続 Home は Provider ストレージ上にそのまま保持されます。

あわせて [Workers](../worker-management/)、[Background Jobs](../background-agent-jobs/)、[cost management](../cost-management/) も参照してください。
