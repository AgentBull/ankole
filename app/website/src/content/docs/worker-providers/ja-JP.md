---
title: WorkerProvider とキャッシュディスク
description: Docker、Kubernetes、Cloudflare、Vercel、Lambda、Function Compute の制約と Home・SQLite キャッシュ要件を確認します。
section: Guides
order: 317
---

WorkerProvider は Agent のコンピューターの実行先と Home・キャッシュの保存方法を決めます。各 Agent は一つの固定 provider と専用 Worker を持ちます。provider はサイトに属し、認証情報は Console の別フィールドに暗号化保存します。設定 YAML に鍵を記載しないでください。作成と日常操作は [Worker](../worker-management/)を参照してください。

Vercel には Control Plane Plugin `vercel-worker-provider` が必要です。Alibaba Function Compute には、モデルアダプターも提供する `china-market-ai-providers` が必要です。使用前に必要な Plugin を有効にして control plane を再起動してください。既存環境ではアップグレード前に該当する Plugin ID を選択します。休止中や削除待ちを含め、Agent が Plugin の Worker provider を参照している間は無効にできません。

## 三つのストレージ

| 保存先 | 内容 | 永続性 |
| --- | --- | --- |
| Agent Home：`/workspace` | 作業領域、ソフトウェア、`/workspace/.codex` のスレッド | インスタンス削除とイメージ変更後も保持し、バックアップする |
| Worker キャッシュ：`/var/cache/ankole` | `codex/` 内の SQLite、WAL、プロセスロック | 再構築可能。Agent ごとに専用 |
| control plane ドライブ | 添付、公開ファイル、Skill、Automation スクリプト | PostgreSQL の参照と OpenDAL のバイトを一緒にバックアップする |

ドライブの S3 バケットは Home や SQLite キャッシュの代わりになりません。Cloudflare の R2 Home バックアップ、Function Compute の OSS Home も別設定です。[ドライブ設定](../drive-storage/)を参照してください。

## Provider の比較

| `kind` | Home | キャッシュ | アイドル時 | インスタンス期限 |
| --- | --- | --- | --- | --- |
| `docker` | 専用ローカル named volume | 専用ローカル named volume | コンテナ削除 | adapter 固定期限なし |
| `kubernetes` | 専用 PVC または共有 PVC の Agent ディレクトリ | 専用 PVC または `emptyDir` | Pod 削除 | adapter 固定期限なし |
| `cloudflare` | 起動時に R2 から復元、通常終了前にバックアップ | インスタンスディスク | バックアップ後に削除 | プラットフォームに従う |
| `vercel` | Agent 専用 Drive | インスタンスディスク | sandbox 削除 | 設定可能、既定は 24 時間 |
| `lambda` | EFS の Agent ディレクトリ | インスタンスディスク | メモリを保持して休止 | 休止を含め 8 時間 |
| `function_compute` | AgenticSpace または OSS の Agent prefix | インスタンスディスク | メモリを保持して休止 | 24 時間 |

これは Ankole adapter の制約です。プラットフォーム全仕様ではありません。アカウント quota、plan、利用可能 region も確認してください。ACS は WorkerProvider に未登録です。

全 6 種類の `idleReleaseAfter` は既定で `15m`、`never` も指定できます。アイドル回収設定はプラットフォーム期限を延長しません。場所、保存キー、provider 種類、既存 Agent の割り当ては変更できません。仕様、環境変数、endpoint の変更はアイドル Worker を置換します。seed は provider テーブルが空のときだけ取り込み、以後は Console で編集します。

## Provider ごとの要件

### Docker

- ローカル Engine と `local` volume driver を使い、開発や単一ホストに適します。置換で volume は残りますが、ホスト消失で Home を失います。別マシンにバックアップしてください。
- control plane に Docker socket アクセスが必要です。Compose の `ANKOLE_DOCKER_GID` を socket の group に合わせます。この権限はホスト root と同等です。
- `network` から control plane と外部サービスへ接続できる必要があります。capability や security-option の上書き設定は受け付けません。
- Home とキャッシュは別 volume です。ローカルキャッシュをネットワークファイルシステムに置き換えないでください。

### Kubernetes

- `storage.claimTemplate` または `storage.sharedClaim` を選びます。複数ノードの共有 Home は `ReadWriteMany` が必要です。専用ブロックストレージは `ReadWriteOnce`、CSI 対応時は `ReadWriteOncePod` を使えます。キャッシュは別ブロック PVC または `emptyDir` にします。
- 信頼された Worker プロセスは root、モデルのコマンドは uid 1000 で動きます。Worker と削除 helper Pod は baseline Pod Security の許可が必要で、restricted に適合しません。
- Home は root の書き込みと uid 1000 への所有権変更を許可するか、全アクセスを uid 1000 にマッピングします。このマッピングがない root-squash NFS は要件を満たしません。
- control plane に Pod、Secret、PVC、削除 helper の RBAC が必要です。remote kubeconfig は全 3 `endpoints` の明示が必要で、ローカル `ownerConfigMap` は使えません。作成後に in-cluster と remote kubeconfig を切り替えられません。
- 新ノードに Worker イメージを事前取得します。イメージ準備処理は Kubernetes の pull を実行しません。通常の Pod 削除完了を待ち、強制削除や grace 0 でノード障害を回避しないでください。

### Cloudflare

- [Cloudflare adapter](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers) を先にデプロイし、Worker イメージ対応、R2、別の `adapterToken` を設定します。
- ディスクにはイメージ、復元 Home、キャッシュ、一時ファイルが収まる必要があります。R2 容量でディスクは増えません。`lite`、`standard-1`～`standard-4`、カスタム仕様を使えますが、[Cloudflare 制限](https://developers.cloudflare.com/containers/platform/limits/)も満たす必要があります。
- 通常回収は先に Home をバックアップします。強制停止で最終バックアップ以後の書き込みを失う場合があります。バックアップ失敗を回収成功と扱いません。`stopGraceSeconds` は既定 300 秒です。
- 現行の公開 file relay は control plane 1 レプリカを必要とします。S3 ドライブに変えてもこの制限は残ります。

### Vercel

- 同一 region の専用 Drive を Home に使います。`teamId`、`projectId`、`region`、`driveSizeGiB` は作成後に変更できません。
- project の VCR に `linux/amd64` イメージを準備し、対象 digest を使います。`cpus` は 1 または 2～32 の偶数、メモリは vCPU ごとに 2048 MiB です。
- `sessionTimeoutSeconds` の既定値は 86400（24 時間）です。アカウントの上限が 45 分の場合は 2700 に設定します。この上限が適用される試用アカウントも同様です。アカウントの実際の上限を超えない値を指定してください。[Vercel の期限](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)を参照してください。sandbox 削除で Drive は残り、キャッシュは失われます。
- 短時間の起動、ファイル保持、イメージ置換、Drive 削除は検証済みです。OOM、ホスト障害、全 24 時間の動作は対象環境での検証が必要です。

### AWS Lambda MicroVMs

- Lambda MicroVMs を使います。`arm64` Worker イメージ、ビルド用 S3 バケットと IAM role、VPC network connector、接続可能な EFS が必要です。
- 公式イメージは `memoryMiB: 4096` または `8192` のみ受け付けます。保存済みの低い値は Console で修正しないと実行もクリーンアップも進みません。`env` は最大 47 項目、`stopGraceSeconds` は最大 59 秒です。
- メモリ quota は実行中、休止中、ストレージ削除 helper を含みます。休止では容量を解放しません。削除後も AWS の終了確認を待ちます。[MicroVM の quota と lifecycle](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)を参照してください。
- Home は EFS、SQLite はインスタンスディスクです。8 時間は休止を含みます。古いビルドオブジェクトとイメージは自動回収しません。失敗時はビルド role、イメージ、接続を修正して再試行します。
- 短いメモリ休止、EFS 保持、削除は検証済みです。長い休止と全期限はデプロイ環境で検証してください。

### Alibaba Function Compute

- ACR Enterprise の `amd64` イメージから第 2 世代 template を作成します。Team、Sandbox API key、POP AccessKey、権限を持つ RAM role が必要です。template 保存時に Agent の識別情報や認証情報は含めません。
- `storage.agenticFs` または `storage.oss` を選びます。AgenticFS は VPC、filesystem、region/zone、容量とファイル数 quota が必要です。access point は mount 前に利用可能である必要があります。[AgenticFS Volume](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume)を参照してください。
- イメージには OSSFS2 2.0.10 以降が必要で、mount 前の `/workspace` は空である必要があります。公式 Worker イメージはこの要件を満たし、entry が mount 後に実行用ディレクトリを作成します。
- OSS は本 Agent の `<root>/<agent_uid>` のみを mount し、完全な POSIX semantics はありません。SQLite を OSS に置かないでください。`chown` 失敗だけでは書き込み不能と判定できません。
- provider `env` は変数を追加できますが、イメージが記録した変数を上書きできません。pause はメモリを保持し、resume は新しい 24 時間 timeout を使います。旧 template は自動回収しません。
- 再開時はイメージ内の補助プログラムで OSSFS2 の接続を作り直し、mount と開いたファイルを保持します。これにより、休止中に使用不能になった TCP 接続での読み取り待ちを防ぎます。補助プログラムが失敗した場合、プロバイダーはそのインスタンスを削除し、次の調整で Home から再構築します。このプログラムを含む Worker イメージと対応するコントロールプレーンを使用してください。AgenticFS は引き続き実環境での検証が必要です。

外部 provider と remote Kubernetes は、インスタンスから接続できる `runtimeFabricUrl`、`relayOrigin`、`aiGatewayUrl` が必要です。到達できない Compose service 名や cluster 内限定アドレスを使わないでください。

`endpoints.relayOrigin` を明示した provider は control plane 1 レプリカが必要です。転送先は relay を所有するノードである必要があり、公式 Helm は複数レプリカを拒否します。Vercel、Lambda、Function Compute、remote Kubernetes にも適用します。

## キャッシュディスクの要件

SQLite とプロセスロックには、信頼できるロック、共有メモリ、原子的ファイル操作、uid 1000 の読み書きが必要です。ローカル SSD、filesystem として mount したブロックデバイス、ノードの `emptyDir` を使います。NFS、EFS、SMB、S3/R2/OSS の FUSE mount を Codex SQLite キャッシュに使わないでください。[SQLite WAL](https://www.sqlite.org/wal.html) はネットワーク filesystem をサポートしません。

Agent ごとに専用ディレクトリ/PVC を使います。空き容量、inode、ノードの一時ストレージを監視します。一律の最小容量保証はありません。公式 Helm のキャッシュ PVC は既定 20 GiB で、実際のログ、並列数、作業に合わせて調整します。

native Kubernetes provider YAML の永続キャッシュ例です。StorageClass は実環境に合わせます。

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

一時キャッシュは次の設定です。

```yaml
cache:
  sizeLimit: 5Gi
```

これらは provider YAML です。Helm values は `worker.cache.type: pvc`、`worker.cache.size`、`worker.cache.storageClass` または `worker.cache.type: emptyDir` を使います。両形式を混ぜないでください。

Docker cache volume と Kubernetes cache PVC は通常回収、イメージ変更、通常のインスタンス設定置換で保持します。明示的な再構築はキャッシュを削除し、キャッシュ設定の変更はキャッシュを置換します。`emptyDir` と外部 provider のディスクはインスタンス削除で失われます。Home は保持されます。app-server 動作中に SQLite、WAL、ロックファイルを削除しないでください。

起動チェックはディレクトリアクセスと基本読み書きのみで、ネットワークストレージの SQLite ロックを保証しません。ロックエラー、容量不足、未バインド PVC は **Workers → Reason**、プラットフォームイベント、mount 種別を先に確認します。[性能調整](../performance-tuning/)と[バックアップ](../backup-and-restore/)を参照してください。
