---
title: WorkerProvider とキャッシュディスク
description: Docker、Kubernetes、Cloudflare、Vercel、Lambda、Function Compute 各バックエンドの制約と、永続 Home および SQLite キャッシュディスクの要件を説明します。
section: Guides
order: 317
---

WorkerProvider は、Agent Computer をどの基盤で動かし、永続 Home とキャッシュをどこに保存するかを定義する設定です。各 Agent には作成時に固定された 1 つのプロバイダーと専用 Worker が割り当てられます。プロバイダーはサイトスコープに属し、プラットフォームの認証情報は Console の専用欄に暗号化して保存します（設定 YAML の中にシークレットキーを直接書かないでください）。プールの作成手順や日常の確認操作については、[Worker](../worker-management/) を参照してください。

なお、Vercel バックエンドを使うには Control Plane Plugin の `vercel-worker-provider` が必要であり、Alibaba Function Compute を使うにはモデルアダプターも同梱する `china-market-ai-providers` が必要です。利用を始める前に該当プラグインを有効化し、コントロールプレーンを再起動してください。休止中や削除待ちの状態も含め、そのプロバイダー種別を参照する Agent Worker が 1 つでも残っている間はプラグインを無効化できません。

## 三つのストレージ

Ankole では用途の異なる 3 つのストレージ領域を明確に使い分けます。

| 保存先 | 格納される内容 | 永続性とバックアップ方針 |
| --- | --- | --- |
| Agent Home（`/workspace`） | 作業ディレクトリ、追加導入したユーザーツール、`/workspace/.codex` 内のスレッド履歴 | インスタンス削除やイメージ更新後も保持される。定期的なバックアップが必要 |
| Worker キャッシュ（`/var/cache/ankole`） | `codex/` 配下の SQLite DB、WAL、プロセスロックファイル | 破棄しても再構築可能。Agent ごとに専用領域を割り当てる |
| コントロールプレーンドライブ | 添付ファイル、公開ファイル、カスタム Skill、Automation スクリプト | PostgreSQL 上の参照メタデータと OpenDAL ストレージの実体データをセットでバックアップする |

コントロールプレーンドライブ用の S3 バケットを、そのまま Agent Home や SQLite キャッシュの保存先として流用することはできません。また、Cloudflare の R2 Home バックアップや Function Compute の OSS Home も、それぞれ個別のストレージ設定です。ドライブ側の設定については [ドライブ設定](../drive-storage/) を参照してください。

## Provider の比較

| `kind` | 永続 Home | キャッシュ | アイドル時の挙動 | インスタンスの最大稼働期限 |
| --- | --- | --- | --- | --- |
| `docker` | 専用ローカル named volume | 専用ローカル named volume | コンテナを削除 | アダプター側の固定期限なし |
| `kubernetes` | 専用 PVC、または共有 PVC 内の Agent ディレクトリ | 専用ブロック PVC または `emptyDir` | Pod を削除 | アダプター側の固定期限なし |
| `cloudflare` | 起動時に R2 から復元し、通常停止前にバックアップ | インスタンスローカルディスク | バックアップ完了後に削除 | Cloudflare 側の制限に準拠 |
| `vercel` | Agent 専用 Drive | インスタンスローカルディスク | サンドボックスを削除 | 設定可能（既定は 24 時間） |
| `lambda` | EFS 上の Agent ディレクトリ | インスタンスローカルディスク | メモリ状態を保持して休止 | 休止時間を含めて最大 8 時間 |
| `function_compute` | AgenticSpace または OSS 上の Agent プレフィックス | インスタンスローカルディスク | メモリ状態を保持して休止 | 24 時間 |

上記は Ankole アダプターとしての動作仕様です。実際の運用にあたっては、クラウド契約ごとのクォータ上限、料金プラン、利用可能リージョンもあわせて確認してください。

全 6 種別とも `idleReleaseAfter` の既定値は `15m` であり、`never` を指定して自動解放を無効化することもできます（ただし、`never` にしてもクラウド基盤側の最大稼働期限自体は延びません）。保存先ロケーション、ストレージキー、プロバイダー種別、および既存 Agent の割り当て先は作成後に変更できません。インスタンス仕様、環境変数、接続先エンドポイントを変更した場合は、アイドル状態の Worker から順次新しい構成へ入れ替わります。なお、起動時のシード YAML はプロバイダーテーブルが空のときに一度だけ取り込まれるため、以降の編集は Console から行ってください。

## Provider ごとの要件

### Docker

- ローカルの Docker Engine と `local` ボリュームドライバーを使用する構成で、開発環境や単一ホスト運用に適しています。コンテナの入れ替え後もボリュームは残りますが、ホストマシンのディスク障害時には Home ごと失われるため、必ず別ホストや外部ストレージへバックアップしてください。
- コントロールプレーンから Docker ソケットへアクセスできる必要があります。Compose 環境ではソケットのグループ ID に合わせて `ANKOLE_DOCKER_GID` を設定してください（この権限はホストの root 権限と同等です）。
- 指定した `network` からコントロールプレーンおよび必要な外部サービスへ通信できる必要があります。Linux ケーパビリティや `security-opt` の上書き指定は受け付けません。
- Home とキャッシュには別々のボリュームが割り当てられます。ローカルキャッシュ用の領域をネットワークファイルシステムに置き換えないでください。

### Kubernetes

- Home 用ストレージには `storage.claimTemplate`（専用 PVC）または `storage.sharedClaim`（共有 PVC）を選択します。複数ノードから共有 PVC を使う場合は `ReadWriteMany` が必要です。専用ブロックストレージを使う場合は `ReadWriteOnce`（CSI ドライバーが対応していれば `ReadWriteOncePod`）を指定できます。キャッシュには別のブロック PVC または `emptyDir` を使用します。
- コンテナ内の信頼された Worker 親プロセスは `root` で起動し、モデルが実行するコマンド類は `uid 1000` で動作します。そのため、Worker Pod と削除ヘルパー Pod には Pod Security Standards の `baseline` レベルが必要であり、`restricted` プロファイルでは動作しません。
- Home ボリュームは、`root` による書き込みと `uid 1000` への `chown` を許可するか、あるいは最初からすべてのアクセスを `uid 1000` にマッピングしている必要があります。ID マッピングなしの標準的な root-squash NFS はこの要件を満たせません。
- コントロールプレーンの ServiceAccount には、Pod、Secret、PVC、および削除ヘルパーを操作する RBAC 権限が必要です。リモートクラスタの kubeconfig を指定する場合は 3 つの `endpoints` すべてを明示する必要があり、ローカル用の `ownerConfigMap` は使えません。また、作成後に in-cluster 接続とリモート kubeconfig 接続を切り替えることはできません。
- 新しく追加されるクラスタノードには Worker イメージを事前に pull しておいてください（Ankole のイメージ準備処理が Kubernetes ノード上の pull を代行することはありません）。また、Pod 停止時は通常の削除完了を待ち、ノード障害時に強制削除や `--grace-period=0` で回避しないでください。

### Cloudflare

- 先に [Cloudflare アダプター](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers)をデプロイし、対応する Worker イメージ、R2 バケット、および専用の `adapterToken` を設定します。
- インスタンスのローカルディスク内に、コンテナイメージ、R2 から展開される Home、キャッシュ、一時ファイルのすべてが収まる必要があります（R2 の容量が大きくてもローカルディスク上限は増えません）。`lite`、`standard-1`〜`standard-4`、またはカスタム仕様を指定できますが、[Cloudflare Containers の上限](https://developers.cloudflare.com/containers/platform/limits/)内に収めてください。
- 通常のアイドル回収では、先に Home を R2 へバックアップしてからインスタンスを削除します（バックアップに失敗した場合は回収完了とはみなされません）。ただし、クラッシュなどの強制停止時には前回バックアップ以降の書き込みが失われる場合があります。`stopGraceSeconds` の既定値は `300` 秒です。
- 公開ファイルリレーはコントロールプレーン 1 レプリカ構成を前提としています。ドライブの保存先を S3 に変更してもこの要件は変わりません。

### Vercel

- 同一リージョンの専用 Drive を Home として使用します。作成後に `teamId`、`projectId`、`region`、`driveSizeGiB` を変更することはできません。
- 対象プロジェクトの VCR に `linux/amd64` イメージをプッシュし、その digest を指定します。`cpus` には `1` または `2`〜`32` の偶数を指定でき、メモリは vCPU あたり `2048 MiB` が割り当てられます。
- `sessionTimeoutSeconds` の既定値は `86400`（24 時間）です。トライアルアカウントなど上限が 45 分に制限されている環境では `2700` 以下に設定し、契約プランの実際の上限を超えないようにしてください（詳しくは [Vercel Sandbox の制限ドキュメント](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)を参照）。サンドボックス削除後も Drive 上の Home は残りますが、ローカルキャッシュは消去されます。

### AWS Lambda MicroVMs

- Lambda MicroVMs 上で稼働します。`arm64` 版の Worker イメージ、ビルド用の S3 バケットと IAM ロール、VPC ネットワークコネクター、および到達可能な EFS ファイルシステムが必要です。
- 公式イメージが受け付けるメモリ設定は `memoryMiB: 4096` または `8192` のみです。これより小さい値が保存されていると起動もクリーンアップも進まないため、Console から修正してください。また、`env` は最大 47 個、`stopGraceSeconds` は最大 59 秒までです。
- AWS アカウントのメモリクォータは、稼働中インスタンス、休止中インスタンス、およびストレージ削除ヘルパーの合計に対して消費されます（休止状態でもクォータ枠は解放されず、削除時も AWS 側の終了確認まで待機します）。詳しくは [Lambda MicroVMs のクォータとライフサイクル](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)を参照してください。
- Home は EFS 上、SQLite キャッシュはインスタンスローカルディスク上に置かれ、最大 8 時間の稼働期限には休止中の時間も含まれます。古いビルド成果物やイメージは自動削除されません。起動失敗時はビルドロール、イメージ、VPC / EFS 接続を見直してから再試行してください。

### Alibaba Function Compute

- ACR Enterprise 上の `amd64` イメージから第 2 世代テンプレートを作成します。Team 設定、Sandbox API キー、POP AccessKey、および必要な権限を持つ RAM ロールが必要です（保存されるテンプレート自体には Agent 固有の識別子や認証情報は含まれません）。
- Home ストレージには `storage.agenticFs` または `storage.oss` を選択します。AgenticFS を使う場合は VPC、ファイルシステム、リージョン / ゾーン、容量およびファイル数クォータの設定が必要で、マウント前にアクセスポイントが利用可能になっている必要があります（[AgenticFS Volume ドキュメント](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume)を参照）。
- コンテナイメージには OSSFS2 `2.0.10` 以降が必要であり、マウント前の `/workspace` ディレクトリは空でなければなりません。公式の Worker イメージはこの条件を満たしており、マウント完了後にエントリポイントが必要な作業ディレクトリを作成します。
- OSS バックエンドでは対象 Agent の `<root>/<agent_uid>` プレフィックスのみをマウントします。OSSFS には完全な POSIX ファイルシステム互換性がないため、SQLite キャッシュを OSS 上に置かないでください（なお、OSS 上では `chown` が失敗すること自体は正常であり、それだけで書き込み不能とは判定されません）。
- プロバイダーの `env` で環境変数を追加することはできますが、コンテナイメージ側で定義済みの変数を上書きすることはできません。休止（pause）中はメモリ状態を保持し、再開（resume）時には新しい 24 時間のタイムアウト枠が適用されます。古いテンプレートは自動削除されません。
- 休止からの再開時には、イメージ内の補助プログラムがマウントと開いているファイルディスクリプタを維持したまま OSSFS2 の通信セッションだけを張り直し、休止中に切れた TCP コネクションで読み取りがハングするのを防ぎます。万が一この補助プログラムが失敗した場合はそのインスタンスを破棄し、次回の調整（reconcile）時に Home から再構築します。必ずこの補助プログラムを含む対応バージョンの Worker イメージとコントロールプレーンを組み合わせてください。

なお、クラウド系の外部プロバイダーおよびリモート Kubernetes 構成では、Worker インスタンス側から実際に到達できる `runtimeFabricUrl`、`relayOrigin`、`aiGatewayUrl` を設定する必要があります。Docker Compose 内部のサービス名やクラスタ内部専用のローカルアドレスを指定しないでください。

また、`endpoints.relayOrigin` を明示的に指定するプロバイダー（Vercel、Lambda、Function Compute、リモート Kubernetes など）を利用する場合は、コントロールプレーンを **1 レプリカ** で運用する必要があります。ファイル転送リクエストがリレーを保持している同一ノードに届く必要があり、公式 Helm チャートでも複数レプリカ構成はエラーとして拒否されます。

## キャッシュディスクの要件

Codex の SQLite データベースとプロセスロックが正しく動作するには、信頼できるファイルロック、共有メモリ（mmap）、アトミックなファイル置換、および `uid 1000` での読み書き権限が不可欠です。キャッシュ領域には必ずローカル SSD、ファイルシステムとしてマウントしたブロックデバイス、またはノードローカルの `emptyDir` を使用してください。NFS、EFS、SMB、あるいは S3 / R2 / OSS の FUSE マウント上に Codex の SQLite キャッシュを置かないでください（[SQLite の WAL モード](https://www.sqlite.org/wal.html)はネットワークファイルシステムに対応していません）。

キャッシュ用のディレクトリや PVC は Agent ごとに専用で割り当て、空き容量、inode 使用率、ノードの一時ストレージ使用量を監視してください。ワークロードによって消費量が変わるため一律の最小サイズは決まっていませんが、公式 Helm チャートではキャッシュ PVC の既定値を `20 GiB` としており、実際のログ量や並列度に合わせて調整できます。

ネイティブ Kubernetes プロバイダー YAML で永続ブロック PVC をキャッシュに使う設定例は次のとおりです（`storageClassName` は実環境に合わせて変更してください）。

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

一時ストレージ（`emptyDir`）を使う場合は次のように指定します。

```yaml
cache:
  sizeLimit: 5Gi
```

上記はいずれも WorkerProvider の YAML 書式です。Helm の `values.yaml` 側で指定する場合は、`worker.cache.type: pvc`・`worker.cache.size`・`worker.cache.storageClass`、または `worker.cache.type: emptyDir` を使用し、2 つの書式を混同しないよう注意してください。

Docker のキャッシュボリュームと Kubernetes のキャッシュ PVC は、通常のアイドル回収やイメージ更新、一般的なスペック変更による入れ替え時にもそのまま引き継がれます。明示的な再構築（rebuild）を実行するとキャッシュが消去され、キャッシュ設定自体を変更すると新しいボリュームへ置き換わります。一方、`emptyDir` や外部クラウドプロバイダーのローカルディスク上のキャッシュはインスタンス削除とともに消えますが、永続 Home 側のデータは保持されます。なお、`app-server` の稼働中に SQLite ファイル、WAL ファイル、ロックファイルを手動で削除しないでください。

Worker 起動時のセルフチェックで確認できるのはディレクトリの存在と基本的な読み書き可否までであり、ネットワークストレージ上での SQLite ロック不整合までは事前検知できません。ロックエラー、ディスク容量不足、PVC の未バインドが発生した際は、まず **Workers → Reason**、プラットフォーム側のイベントログ、およびマウント種別を確認してください。あわせて [性能調整](../performance-tuning/) と [バックアップ](../backup-and-restore/) も参照してください。
