---
title: Worker
description: Console で Agent Computer Worker の状態、容量、heartbeat を確認し、よくある障害を解決する。
section: User guide
order: 52
---

Agent Computer Worker は、Agent が作業をするコンピューターです。control plane が作業を管理し、割り当てます。Worker は Agent、tool、ファイル操作を実行します。1 つのデプロイインスタンスは 1 つ以上の Worker に接続できます。

## Worker を表示する

**Console → Workers** を開きます。各行には次のものが表示されます。

- **State:** その Worker が新しい作業を受け入れられるかどうか。
- **Slots:** 同時に実行できる Agent Turn の最大数。
- **Active turns:** 現在実行中の Turn の数。
- **Last heartbeat:** control plane が最後に Worker の状態を受け取った時刻。
- **Version:** Worker 上の Ankole バージョン。

少なくとも 1 つの Worker が ready である限り、control plane は作業を割り当てられます。最近の heartbeat がない Worker は、通常、コンテナの停止、ネットワークの問題、または Worker と control plane の間の認証失敗を意味します。

**Browse files** を選択すると、その Worker 上の Agent ファイルを検査できます。手順は [File management](../file-management/) を参照してください。

## ready な Worker がない場合

次の項目を順番に確認してください。

1. Worker のコンテナまたは Pod が実行されている。
2. Worker ログに、control-plane アドレス、認証、接続エラーが表示されていない。
3. control plane と Worker が同じ `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` を使っている。
4. Worker が control plane の Runtime Fabric アドレスに到達できる。
5. control plane と Worker が互換性のある Ankole バージョンを使っている。

Docker Compose の場合:

```bash
docker compose ps agent-computer-worker
docker compose logs agent-computer-worker
```

Kubernetes の場合:

```bash
kubectl -n ankole get pods
kubectl -n ankole logs deployment/ankole-agent-computer-worker
```

正確なリソース名は release 名に依存します。コマンドがオブジェクトを見つけられない場合は、`kubectl -n ankole get deployments` で探してください。

## Worker は ready だが作業が待機したままの場合

**Active turns** と **Slots** を比較してください。すべての Worker がスロットを使い切っている場合、新しい作業は容量を待ちます。

短い待機は正常です。待機が続く場合は、まず LLM Provider が遅くないことを確認してください。その後、Worker を追加するか、Worker ごとの容量を増やすか、並行作業を減らすかを決めます。[Performance tuning](../performance-tuning/) を参照してください。

## Worker を再起動する

Worker が応答せず、ログが復旧できないことを示している場合にのみ、再起動してください。

Docker Compose:

```bash
docker compose restart agent-computer-worker
```

Kubernetes:

```bash
kubectl -n ankole rollout restart deployment/ankole-agent-computer-worker
```

再起動は、その Worker で実行中の Turn を中断します。control plane は、それらの再試行ポリシーに従って処理します。再起動後、**Console → Conversations** または **Background Agent Jobs** で結果を確認してください。