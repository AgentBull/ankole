---
title: パフォーマンスチューニング
description: 容量ノブ — 同時ターン、データベースプール、Postgres の最大接続数、worker ターン上限、agent ごとの Job スロット — と、デプロイメントインスタンスが一度にどれだけ処理できるかを決める、それらの間の関係。
section: Guides
order: 319
---

Ankole のパフォーマンスはほとんど容量の問題です: 同時にいくつのターンが実行され、それが引き出せるデータベース接続がいくつあり、agent が並行して実行できる Job がいくつか。このページはノブの名前と既定値を示し、そして重要な部分、それらがどう関係するかを説明します。他のノブを動かさずに 1 つだけ動かすと、遅いデプロイメントインスタンスか、失敗するインスタンスのどちらかになるからです。

決定的な性質を先に述べます: ノブは連鎖を形成します。同時ターンはデータベース接続を必要とし、データベース接続は Postgres によって上限が決まり、Job スロットは agent が実行できるターンを掛け算します。他を上げずに 1 つを上げると、連鎖は最も弱いリンクで切れます — ターンがキューに溜まるか、接続が枯渇するか、Postgres が接続を拒否します。ロードの形状に合わせて、1 つずつではなくセットとしてチューニングしてください。

## 容量の連鎖

ターンはコントロールプレーン（データベースプールを使用）、worker（モデルループを実行）、Postgres（プールにサービスを提供）に触れます。関係を 1 行で:

```text
(同時ターン) × (ターンごとの接続数)  ≤  データベースプールサイズ  ≤  Postgres の max_connections
```

すべてのターンはデータベース作業を保持し、すべてのデータベース接続は Postgres から来ます。同時ターンの設定がプールが許すより多くの接続を意味するなら、ターンはプールにキューイングされます。プールサイズが Postgres が許すより多くの接続を意味するなら、接続は拒否されます。既定値は小さな単一ホストが動くように設定されています。スケールアウトはそれらを一緒に上げることを意味します。

## ノブ

| ノブ | 既定 | 上限の対象 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_TURNS` | 9 | worker が受け入れる同時 actor ターン |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | コントロールプレーンのデータベース接続プール |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres の `max_connections`（バンドルサーバー） |
| `agent_computer.background_agent_job.max_turns_per_worker` | 設定可能 | Background Agent Jobの worker ごとのターン上限 |
| `max_running_per_agent` | 3 | agent ごとの実行中Background Agent Jobの最大数 |

既定値（ターン 9、プール 10、Postgres 300）は控えめで、小さな単一ホストに適合します。チューニングの問いは、デプロイメントインスタンスがそれより忙しいときに、どれをどれだけ上げるかです。

## 症状に合わせてチューニングする

異なる症状は異なるノブを指します。何かを動かす前に症状を読み取ってください。

### 「ターンの開始が遅い」（キューイング）

ターンは Worker プールが満杯のときにキューイングされます。`ANKOLE_MAX_CONCURRENT_TURNS` は各 Worker の同時ターン上限です。Console がターンの Worker 待ちを示しているなら、データベースプールに余裕があることを確認した後にのみ容量を追加してください。

### 「開始後のターンが遅い」（データベース飽和）

データベース接続を保持するターンは、プールが枯渇すると待ちます。`ANKOLE_DATABASE_POOL_SIZE` を上げてください — ただし Postgres が許す範囲までだけ。バンドル Postgres は既定で 300 接続です。外部サーバーには独自の `max_connections` があります。プールサイズが Postgres の上限に近づいたら、まず Postgres の上限を上げてから（またはバンドルサーバーの `ANKOLE_POSTGRES_MAX_CONNECTIONS` を増やしてから）、プールを上げてください。

### 「Background Agent Jobがキューに溜まる」（agent スロット飽和）

各 agent は最大 `max_running_per_agent`（3）Job を並行実行します。agent の 3 つの Job が `running` で、さらに `queued` があるなら、上限が制限です — worker でもプールでもありません。キューを受け入れるか、さらに多くの agent に作業を分散します（各 agent が自分の 3 スロットを得ます）。`max_running_per_agent` を上げるのはめったに正しい手ではありません。worker ごとのターン上限（`max_turns_per_worker`）とグローバルなターン上限が、いずれにせよそれをフェンス管理します。

### 「provider 呼び出しがボトルネック」（Ankole のノブではない）

`/ai-gateway/conversations` がモデル呼び出しにターン時間の大半を取っていることを示すなら、ボトルネックは Ankole ではなく provider です。どの容量ノブもそれを修正しません。モデル側のレバー（より安い `primary`、より低い `reasoning_effort`）については [Cost management](../cost-management/) を参照してください。これらはターンも速くします。

## 具体的なサイジング

より忙しいデプロイメントインスタンス、たとえば 5 つのアクティブな agent がそれぞれ 1〜2 Job を実行し、channel で応答している場合:

- **同時ターン** — `ANKOLE_MAX_CONCURRENT_TURNS` を現実的なピーク（15〜20）に合わせて上げます。理論上の最大値ではありません。
- **データベースプール** — `ANKOLE_DATABASE_POOL_SIZE` を、プールがキューポイントにならないように上げます（このロードなら 20〜30）。
- **Postgres** — `ANKOLE_POSTGRES_MAX_CONNECTIONS`（300）が、プールと worker 自身の接続と余裕を快適に上回ることを確認します。通常は上回りますが、外部サーバーでは独自の `max_connections` を上げる必要があるかもしれません。
- **agent ごとの Job スロット** — 3 のままにします。上げるよりも、より多くの agent に作業を分散します。

これらの数値は固定の答えではありません。一度に 1 つの制限を変更してください。変更ごとに、キュー、Background Agent Job の状態、データベースメトリクスを比較します。実際のピークを処理できる最小の容量を維持してください。

## worker 数であって、worker 容量だけではない

Kubernetes では、worker は水平方向にスケールできる Deployment です。より多くの worker ポッドがあり、それぞれが独自の `ANKOLE_MAX_CONCURRENT_TURNS` を持ちます。容量の計算はその場合 `worker ポッド数 × worker ごとのターン数` になり、データベースプールと Postgres によって境界付けられます。Compose（単一ホスト）では worker は 1 台です。スケールは、ホストとデータベースが許す範囲までターン上限を上げることを意味します。

単一 worker のホストが限界のときは、水平方向の worker スケーリングがよりきれいな経路です。データベースが限界でホストに余裕があるときは、垂直方向（1 つの worker の上限を上げる）がよりきれいです。

## パフォーマンスチューニングがそうでないもの

パフォーマンスチューニングは、すべての制限を最大に設定することを意味しません。次層を超える容量はボトルネックを移動させるだけです。Console のターンと Job の状態を使ってキューを特定し、その層を変更してください。高い並行性はモデル呼び出しとデータベース接続も多く使うため、[Cost management](../cost-management/) を確認してください。

## 次のステップ

- ノブを環境変数として見るには、[Environment variables](../environment-variables/) を読んでください。
- ターンと Job のエンドポイントについては、[Console API reference](../console-api/) を読んでください。
- 速度にも影響するモデル側のレバーについては、[Cost management](../cost-management/) を読んでください。
- ターンを実行する worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
