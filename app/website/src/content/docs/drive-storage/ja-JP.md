---
title: control plane ドライブ・オブジェクトストレージの設定
description: Ankole.ObjectStore（Agent ドライブ、Pod file ページ、各種添付ファイル、コンパイル済み Applet バンドル）にローカルファイル、クラウドバケット、データベース、SFTP、WebDAV を設定し、移行とバックアップを行います。
section: Guides
order: 318
---

`ANKOLE_FILES_STORE` は control plane のオブジェクトストア（`Ankole.ObjectStore`）を設定し、Agent ドライブ（Worker 停止中も利用可能）、Pod の `file` ページ、Pod ドキュメント/Base/Chat および会話の添付ファイル、コンパイル済み Applet バンドルを保存します。PostgreSQL はパス、権限、内容参照を保存し、OpenDAL backend はコンテンツアドレス指定の blob バイトを保存します。Ankole は `fs`、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp`、`webdav` に対応します。

これはサイトの起動設定で、全 tenant が同じ object store を使います。WorkerProvider の Home、キャッシュ、Cloudflare R2 バックアップは別設定です。[WorkerProvider](../worker-providers/)と[ファイル管理](../file-management/)を参照してください。

## backend の選択

| デプロイ | `ANKOLE_FILES_STORE` | 設定 |
| --- | --- | --- |
| 単一ホストまたは control plane 1 レプリカ | `fs` | 永続 volume またはローカルフォルダー |
| AWS S3 | `s3` | バケット、region、AWS credential chain |
| Cloudflare R2 | `s3` | S3 API endpoint、region `auto`、R2 認証情報 |
| 他の S3 互換サービス | `s3` | endpoint、署名 region、認証情報と互換性検証 |

複数 control plane レプリカでは共有リモートストレージを使い、backend の場所と root を一致させます。公式 Helm は `files.store: fs` で 2 レプリカ以上を拒否します。S3 ドライブは個別 WorkerProvider のレプリカ制約を解除しません。

定期発火、チャット接続、scheduler のハイドレーションなどの singleton プロセスは単一ノードで動作するため、`controlPlane.replicaCount: 1` を設定します。共有リモートストレージは複数レプリカの前提条件ですが、それ単体で複数レプリカ構成が成立するわけではありません。[レプリカの説明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)を参照してください。

## 環境変数

| 変数 | backend | 要件 |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | 全て | 本番必須。対応する backend を選択 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | control plane 内の書き込み可能な絶対パス |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 作成済みバケットの名前 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 必須。AWS はバケットの region、R2 は `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | 互換サービスの endpoint。通常 AWS S3 は省略 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | 任意の object prefix。例：`/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | 任意の固定認証情報。次の項目と同時に設定 |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | 任意の固定認証情報。前の項目と同時に設定 |

固定認証情報がなければ、設定済み EKS Pod Identity を含む既定 AWS credential chain を使います。認証情報は control plane だけに提供します。Worker は RuntimeFabric 経由で自分のドライブを使い、バケットの鍵は不要です。設定変更後は control plane を再起動します。他の OpenDAL パラメータを Ankole 環境変数として追加しないでください。

## その他の OpenDAL backend

環境変数は `ANKOLE_FILES_<SCHEME>_<FIELD>` で、backend 名とフィールド名は大文字です。Azure Blob は `ANKOLE_FILES_STORE=azblob`、`ANKOLE_FILES_AZBLOB_CONTAINER`、`ANKOLE_FILES_AZBLOB_ENDPOINT` を使います。以下は Ankole が公開する全フィールドです。必須値が欠ける、または空の場合は起動に失敗します。

| backend | 必須フィールド | 任意フィールド |
| --- | --- | --- |
| `azblob` | `CONTAINER`, `ENDPOINT` | `ROOT`, `ACCOUNT_NAME`, `ACCOUNT_KEY`, `SAS_TOKEN` |
| `d1` | `ACCOUNT_ID`, `DATABASE_ID`, `TOKEN`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `cos` | `BUCKET`, `ENDPOINT` | `ROOT`, `SECRET_ID`, `SECRET_KEY`, `SECURITY_TOKEN` |
| `postgresql` | `CONNECTION_STRING`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `oss` | `BUCKET`, `ENDPOINT` | `ROOT`, `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`, `SECURITY_TOKEN` |
| `tos` | `BUCKET`, `ENDPOINT`, `REGION` | `ROOT`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SECURITY_TOKEN` |
| `gcs` | `BUCKET` | `ROOT`, `ENDPOINT`, `CREDENTIAL`, `CREDENTIAL_PATH` |
| `sftp` | `ENDPOINT` | `ROOT`, `USER`, `KEY`, `KNOWN_HOSTS_STRATEGY` |
| `webdav` | `ENDPOINT` | `ROOT`, `USERNAME`, `PASSWORD`, `TOKEN` |

認証情報は control plane の Secret に保存します。GCS の `CREDENTIAL` は Base64 エンコードした認証 JSON、`CREDENTIAL_PATH` は元の JSON ファイルのパスです。明示的な認証情報がなければ上流の Google credential chain を使います。SFTP は control plane image の `ssh` を使い、`KEY` は秘密鍵ファイルのパスです。ホスト検証は既定で `strict` なので、control plane ユーザーの `~/.ssh/known_hosts` を用意します。WebDAV は Basic 認証または bearer `TOKEN` に対応します。

D1 と PostgreSQL は作成済みテーブルが必要です。D1 は `TEXT` 主キーと `BLOB` 値、PostgreSQL は `TEXT` 主キーと `BYTEA` 値を使い、`TABLE`、`KEY_FIELD`、`VALUE_FIELD` で指定します。Ankole はテーブルを作成しません。D1、PostgreSQL、WebDAV は native backend 内でオブジェクト全体をバッファーします。D1 の[文字列、BLOB、行の上限は 2,000,000 バイト](https://developers.cloudflare.com/d1/platform/limits/)で、Ankole は行をまたいで分割しません。大きなファイルにはバケット backend を使います。

SFTP はオブジェクトと同じディレクトリの一時ファイルに書き、閉じた後で rename します。サーバーは OpenSSH `posix-rename` などの原子的な置換に対応する必要があります。control plane が途中で停止すると `blobs/<digest>.<uuid>.tmp` が残ることがあります。全 writer を停止した保守時間に削除します。

Helm は `files.store` で backend を選び、通常変数は `controlPlane.extraEnv`、認証変数は `secrets.existingSecret` に設定します。Chart はこの Secret を control plane と migration の環境に読み込みます。同じ Secret のファイルは control plane の `/etc/ankole/bootstrap` に読み取り専用でマウントします。SSH 鍵の権限と `known_hosts` は uid 10001 用に設定します。Compose は以下の override と同じ方法で、選んだ backend の変数を両サービスに渡します。デプロイ前に読み書き、置換、削除、大きなファイルの転送を検証します。

## ローカルフォルダーと永続 volume

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

これは control plane 内のパスです。コンテナには永続ストレージを mount しないと、削除時にファイルを失います。公式イメージの uid/gid 10001 に作成、書き込み、名前変更、削除の権限が必要です。`fs` は root 内に `.tmp` も作成します。

公式 Compose は `files_data` を `/var/lib/ankole/files` に mount します。ホストフォルダーを使う場合は先に作成し、uid/gid 10001 に書き込み権限を与え、override で置き換えます。

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

既存サイトでは先に旧ストアをコピーしてください。空フォルダーの mount で旧 volume は自動移行されません。

Helm のローカル設定：

```yaml
controlPlane:
  replicaCount: 1
files:
  store: fs
  persistence:
    size: 100Gi
    storageClass: YOUR_STORAGE_CLASS
    # existingClaim: YOUR_EXISTING_FILES_PVC
```

Chart は files PVC を作成または引き継ぎ、`/var/lib/ankole/files` に mount します。Chart 作成の PVC は uninstall 後も残ります。既存 PVC も権限とバックアップが必要です。Agent Home は別ストレージです。

## AWS S3

private バケットを作成し、選択 prefix の読み取り、書き込み、削除、multipart upload を control plane の認証主体に許可します。KMS 暗号化を使う場合は KMS 権限も設定します。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS workload identity では Ankole 固定認証変数を省略できます。固定認証では `ANKOLE_FILES_S3_ACCESS_KEY_ID` と `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` の両方を deployment Secret に提供します。

Helm の例：

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

`secrets.existingSecret` は両方の S3 認証変数を持つ bootstrap Secret を参照できます。この Secret にはデプロイに必要な DB 認証情報（`DATABASE_URL`、および同梱 PostgreSQL 有効時の `POSTGRES_PASSWORD`）、元の `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`RELEASE_COOKIE` も含める必要があります。Chart は `secrets.filesS3AccessKeyID` と `secrets.filesS3SecretAccessKey` も受け付けます。実際の鍵を values にコミットしないでください。

## Cloudflare R2 と他の S3 互換サービス

R2 も `s3` backend を使います。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

R2 S3 API 認証情報とアカウントの S3 API endpoint を使います。公開バケットの domain や Worker URL ではありません。region `auto` と操作互換性は [R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/)を参照してください。Helm は `files.s3.endpoint`、`files.s3.region`、`files.s3.root` を使います。

MinIO 等も `s3` に実際の endpoint と署名 region を設定します。S3 互換の表明だけでは検証になりません。読み書き、削除、multipart upload、大きなファイルの転送を確認してください。公開する backend と起動設定はこのページの表を参照してください。S3 virtual-host addressing と独自署名設定は公開していません。上流の [S3 backend](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html)も参照できます。

## Compose で S3 を使う

公式 Compose は YAML に `fs` を指定するため、`.env` の `ANKOLE_FILES_STORE=s3` だけでは変更できません。`compose.files-s3.yaml` 等の override を用意し、migration と control plane に同じ設定を渡します。以下は固定認証の例です。

```yaml
x-files-environment: &files-environment
  ANKOLE_FILES_STORE: s3
  ANKOLE_FILES_S3_BUCKET: ${ANKOLE_FILES_S3_BUCKET:?Set the files bucket}
  ANKOLE_FILES_S3_REGION: ${ANKOLE_FILES_S3_REGION:?Set the files region}
  ANKOLE_FILES_S3_ENDPOINT: ${ANKOLE_FILES_S3_ENDPOINT:-}
  ANKOLE_FILES_S3_ROOT: ${ANKOLE_FILES_S3_ROOT:-/ankole/}
  ANKOLE_FILES_S3_ACCESS_KEY_ID: ${ANKOLE_FILES_S3_ACCESS_KEY_ID:?Set the access key}
  ANKOLE_FILES_S3_SECRET_ACCESS_KEY: ${ANKOLE_FILES_S3_SECRET_ACCESS_KEY:?Set the secret key}
services:
  migrate:
    environment: *files-environment
  control-plane:
    environment: *files-environment
```

`.env` または deployment 環境で値を提供します。新規サイトは次で起動できます。既存サイトでは次節の object 移行を先に完了してください。

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

以後の `run`、`exec`、更新、Home インポートも両方の `-f` を使います。AWS credential chain を使う場合は override の固定認証 2 項目を削除し、コンテナに実際の workload identity を提供します。

## backend、バケット、prefix を変更する

設定変更だけでファイルは移動しません。PostgreSQL の内容参照に対応する object key は root/prefix 内の `blobs/<完全な SHA-256>` です。Agent の論理ドライブパスで命名したフォルダーではありません。

1. 要求と定期処理を停止し、Agent を無効にして作業終了を待ちます。Worker と全 control plane を停止し、ファイル更新と回収も停止します。
2. DB、元の object store、Home、秘密情報をまとめてバックアップします。
3. `blobs/` 全体を移行先 root/prefix に同じ key でコピーします。`fs` の `.tmp` は除外し、論理ドライブパスに名前変更しません。
4. 全 control plane を同じ移行先に変更し、起動後に既知ファイルの内容とダウンロード、新規アップロード、Worker 読み書き、添付送信を確認します。
5. 検証後に作業を戻し、旧ストアはロールバック用に保持します。切り替え後の書き込みを保持して戻す場合は、対応する object と DB 参照も同期します。

独立サイトで一つの prefix を共有しないでください。一方の未参照内容回収が他方の必要な object を削除する可能性があります。同一サイトのレプリカは同じ設定を使います。

## バックアップと回収

DB は参照、バケット/フォルダーは blob バイトを保持するため、一緒に復元します。control plane のガベージコレクションは、Agent ドライブ、Pod `file` ページ、Pod ドキュメント/Base/Chat および会話の添付ファイル、コンパイル済み Applet バンドルのいずれからも参照されなくなった blob を削除します。参照中 object を削除する有効期限規則を設定しないでください。

S3 は multipart upload を使い、プロセス中断で未完了 upload が残る場合があります。作業時間に適した期間で未完了 upload を中止する lifecycle rule を設定します。`fs` は開くときに 1 日以上変更されていない一時ファイルをクリーンアップします。これはバックアップではありません。

Worker 停止中に Console で既知ファイルをアップロード・ダウンロードし、その後一つの Worker でアクセスと添付を確認します。`AccessDenied` は認証主体とバケット権限、`fs` 書き込み失敗は mount・uid 10001・容量、旧ファイル不在はバケット・region・prefix・コピー結果を確認します。[バックアップ](../backup-and-restore/)と [2.0 への更新](../upgrade-to-2/)も参照してください。
