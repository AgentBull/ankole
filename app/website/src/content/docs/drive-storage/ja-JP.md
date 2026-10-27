---
title: control plane ドライブ・オブジェクトストレージの設定
description: Ankole.ObjectStore（Agent ドライブ、Pod file ページ、各種添付ファイル、コンパイル済み Applet バンドル）にローカルファイル、クラウドバケット、データベース、SFTP、WebDAV を設定し、移行とバックアップを行います。
section: Guides
order: 318
---

`ANKOLE_FILES_STORE` は control plane のオブジェクトストア（`Ankole.ObjectStore`）を指定する設定です。ここには Agent ドライブ（Worker 停止中も利用可能）、Pod の `file` ページ、Pod ドキュメント/Base/Chat および会話の添付ファイル、コンパイル済み Applet バンドルが保存されます。パス・権限・内容参照は PostgreSQL が管理し、コンテンツアドレス指定の blob バイト本体は OpenDAL backend が保存します。対応している backend は `fs`、`s3`、`azblob`、`d1`、`cos`、`postgresql`、`oss`、`tos`、`gcs`、`sftp`、`webdav` です。

これはサイト全体の起動時設定であり、すべての tenant が同じオブジェクトストアを使用します。WorkerProvider の Home、キャッシュ、および Cloudflare R2 バックアップとは別設定になるため、詳細については [WorkerProvider](../worker-providers/) と [ファイル管理](../file-management/) を参照してください。

## backend の選択

| デプロイ | `ANKOLE_FILES_STORE` | 設定 |
| --- | --- | --- |
| 単一ホストまたは control plane 1 レプリカ | `fs` | 永続 volume またはローカルフォルダー |
| AWS S3 | `s3` | バケット、region、AWS credential chain |
| Cloudflare R2 | `s3` | S3 API endpoint、region `auto`、R2 認証情報 |
| 他の S3 互換サービス | `s3` | endpoint、署名 region、認証情報と互換性検証 |

control plane を複数レプリカで運用する場合は、共有リモートストレージを使用し、すべてのレプリカで backend の接続先と root を一致させてください。公式 Helm chart では、`files.store: fs` のまま 2 レプリカ以上を指定するとエラーになります。なお、ドライブを S3 にしても、各 WorkerProvider 側のレプリカ制約が解除されるわけではありません。

また、定期実行のトリガー、チャット接続、scheduler のハイドレーションといった singleton プロセスは単一ノードで動作するため、`controlPlane.replicaCount: 1` を設定します。共有リモートストレージは複数レプリカ構成の前提条件ですが、それだけで複数レプリカ構成が成立するわけではありません。詳しくは[レプリカの説明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)を参照してください。

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

固定の認証情報を設定しない場合、Ankole は設定済みの EKS Pod Identity を含む既定の AWS credential chain を使用します。認証情報は control plane にのみ渡してください。Worker は RuntimeFabric 経由で自分のドライブにアクセスするため、バケットの鍵は不要です。設定を変更した後は control plane を再起動してください。なお、表にない OpenDAL パラメータを Ankole の環境変数として追加しないでください。

## その他の OpenDAL backend

環境変数名は `ANKOLE_FILES_<SCHEME>_<FIELD>` の形式で、backend 名とフィールド名はいずれも大文字で指定します。たとえば Azure Blob を使う場合は、`ANKOLE_FILES_STORE=azblob`、`ANKOLE_FILES_AZBLOB_CONTAINER`、`ANKOLE_FILES_AZBLOB_ENDPOINT` を設定します。Ankole が公開している全フィールドは以下のとおりで、必須項目が欠けているか空の場合は起動に失敗します。

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

認証情報は control plane の Secret に保存します。GCS の場合、`CREDENTIAL` には Base64 エンコードした認証 JSON を、`CREDENTIAL_PATH` には元の JSON ファイルパスを指定します。明示的な認証情報がなければ、上流の Google credential chain が使われます。SFTP では control plane イメージ内の `ssh` を使用し、`KEY` には秘密鍵ファイルのパスを指定します。ホスト鍵の検証は既定で `strict` のため、control plane 実行ユーザーの `~/.ssh/known_hosts` をあらかじめ用意してください。WebDAV は Basic 認証または bearer `TOKEN` に対応しています。

D1 と PostgreSQL を backend に使う場合は、事前にテーブルを作成しておく必要があります（Ankole 側では自動作成しません）。D1 では `TEXT` 主キーと `BLOB` 値、PostgreSQL では `TEXT` 主キーと `BYTEA` 値のカラムを用意し、`TABLE`、`KEY_FIELD`、`VALUE_FIELD` で指定します。なお、D1・PostgreSQL・WebDAV は native backend 内でオブジェクト全体をメモリにバッファーします。また、D1 には[文字列、BLOB、行の上限（2,000,000 バイト）](https://developers.cloudflare.com/d1/platform/limits/)があり、Ankole は複数行への分割を行わないため、大きなファイルを扱う環境ではバケット型の backend を選択してください。

SFTP backend は、対象オブジェクトと同じディレクトリ内の一時ファイルへ書き込んでからクローズ後に rename するため、SFTP サーバー側が OpenSSH の `posix-rename` など原子的な置換操作に対応している必要があります。書き込み途中で control plane が停止すると `blobs/<digest>.<uuid>.tmp` が残ることがあるため、すべての writer を停止したメンテナンス時間帯に削除してください。

Helm で構成する場合は、`files.store` で backend を選択し、通常の環境変数は `controlPlane.extraEnv` に、認証情報は `secrets.existingSecret` に設定します。Chart はこの Secret を control plane と migration の両方の環境変数として読み込むほか、同じ Secret の内容を control plane の `/etc/ankole/bootstrap` に読み取り専用ファイルとしてマウントします。SSH 鍵の権限や `known_hosts` は uid 10001 から読み取れるように設定してください。Docker Compose の場合も後述の override と同じ要領で、選択した backend の変数を両サービスに渡します。本番投入前に、読み書き・置換・削除・大容量ファイルの転送を一通り検証してください。

## ローカルフォルダーと永続 volume

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

`ANKOLE_FILES_FS_ROOT` は control plane コンテナ内のパスです。ここに永続ストレージを mount しないと、コンテナ削除時にファイルが失われます。公式イメージの実行ユーザー（uid/gid 10001）に対して、作成・書き込み・名前変更・削除の権限を付与してください。`fs` backend はこの root 直下に一時ディレクトリ `.tmp` も作成します。

公式の Docker Compose 設定では、`files_data` volume が `/var/lib/ankole/files` に mount されます。代わりにホスト側のディレクトリをバインドマウントする場合は、あらかじめディレクトリを作成して uid/gid 10001 に書き込み権限を付与したうえで、override ファイルで差し替えてください。

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

既存サイトでマウント先を切り替える場合は、先に旧ストアのデータをコピーしてください。空のフォルダーを mount しても、旧 volume からデータが自動移行されることはありません。

Helm でのローカルストレージ設定例は以下のとおりです。

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

Chart は files 用の PVC を新規作成（または既存 PVC を引き継ぎ）して `/var/lib/ankole/files` に mount します。Chart が作成した PVC は `helm uninstall` 後も削除されずに残ります。既存 PVC を使う場合も、適切な権限設定とバックアップが必要です。なお、Agent Home はこれとは別のストレージとして管理されます。

## AWS S3

private バケットを作成し、指定した prefix 配下に対する読み取り・書き込み・削除・multipart upload の権限を control plane の IAM 主体に付与します。KMS 暗号化を使用する場合は、対応する KMS キー権限もあわせて付与してください。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS の workload identity（IAM Roles for Service Accounts や EKS Pod Identity など）を利用する場合は、固定の認証情報変数を省略できます。固定キーを使う場合は、`ANKOLE_FILES_S3_ACCESS_KEY_ID` と `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` の両方をデプロイメントの Secret に設定してください。

Helm の設定例は以下のとおりです。

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

`secrets.existingSecret` には、上記の S3 認証変数 2 つを含む bootstrap Secret を指定できます。この Secret には、デプロイに必要な DB 接続情報（`DATABASE_URL`、および同梱 PostgreSQL 有効時の `POSTGRES_PASSWORD`）、元の `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`RELEASE_COOKIE` もあわせて含める必要があります。Chart は `secrets.filesS3AccessKeyID` と `secrets.filesS3SecretAccessKey` も受け付けますが、実際の秘密鍵を平文のまま values ファイルにコミットしないでください。

## Cloudflare R2 と他の S3 互換サービス

Cloudflare R2 も `s3` backend を使用して接続します。

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

R2 の S3 API 認証情報と、アカウント固有の S3 API endpoint を指定してください（公開バケット用のカスタムドメインや Worker URL ではありません）。region `auto` の扱いや API の互換性については、[R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/) を参照してください。Helm では `files.s3.endpoint`、`files.s3.region`、`files.s3.root` で設定します。

MinIO などの S3 互換ストレージでも同様に、`s3` backend に対して実際の endpoint と署名用 region を設定します。「S3 互換」と謳われていても挙動が異なる場合があるため、事前に読み書き・削除・multipart upload・大容量ファイルの転送を必ず実機で検証してください。Ankole が公開している backend と起動設定はこのページの表に記載されたものに限られており、S3 の virtual-host addressing や独自の署名設定は公開していません。仕様の詳細については上流の [S3 backend](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html) ドキュメントも参照できます。

## Compose で S3 を使う

公式の `compose.yaml` では `ANKOLE_FILES_STORE` が `fs` に固定されているため、`.env` に `ANKOLE_FILES_STORE=s3` を書くだけでは切り替わりません。`compose.files-s3.yaml` などの override ファイルを用意し、`migrate` と `control-plane` の両方に同じ設定を渡してください。固定認証情報を使う場合の例は以下のとおりです。

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

実際の変数値は `.env` またはデプロイ環境から渡します。新規サイトであれば次のコマンドでそのまま起動できますが、既存サイトの場合は起動前に次節の手順でオブジェクトの移行を完了させてください。

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

これ以降、`run`、`exec`、アップグレード、Home のインポートを実行する際も、常に両方の `-f` オプションを指定してください。AWS credential chain を利用する場合は、override から固定認証の 2 項目を削除し、コンテナに workload identity を割り当てます。

## backend、バケット、prefix を変更する

設定を変更しただけでは、既存のファイルは新しい保存先へ移動しません。PostgreSQL 上の内容参照に対応するオブジェクトキーは、root/prefix 配下の `blobs/<完全な SHA-256>` であり、Agent の論理ドライブパス名で階層化されたフォルダーではありません。移行は以下の手順で行います。

1. 新規リクエストや定期処理を止め、Agent を無効化して実行中の作業が完了するのを待ちます。その後、Worker とすべての control plane を停止し、ファイルの更新とガベージコレクションが走らない状態にします。
2. データベース、移行元のオブジェクトストア、Home、および秘密情報をまとめてバックアップします。
3. `blobs/` 配下をそのまま同じキー構造で移行先の root/prefix にコピーします。`fs` の `.tmp` は除外し、論理ドライブパスへリネームしないでください。
4. すべての control plane の設定を同じ移行先に変更して起動し、既存ファイルの閲覧・ダウンロード、新規アップロード、Worker からの読み書き、添付ファイル送信が正常に動作することを確認します。
5. 検証が完了したら通常運用に戻し、移行元のストアはロールバック用にしばらく保持します。万一、切り替え後の書き込みを維持したままロールバックする場合は、追加されたオブジェクトと DB 参照の両方を同期してください。

なお、独立した複数のサイトで 1 つの prefix を共有しないでください。一方のサイトで未参照オブジェクトの回収（ガベージコレクション）が実行されると、他方のサイトで必要なオブジェクトまで削除されるおそれがあります。同一サイト内のレプリカ同士でのみ同じ設定を共有してください。

## バックアップと回収

PostgreSQL には参照メタデータが、バケットやフォルダーには実データの blob バイトが保存されるため、リストア時は必ず両方をセットで復元してください。control plane のガベージコレクションは、Agent ドライブ、Pod の `file` ページ、Pod ドキュメント/Base/Chat および会話の添付ファイル、コンパイル済み Applet バンドルのいずれからも参照されなくなった blob を削除します。バケット側で、まだ参照されているオブジェクトまで自動削除してしまう有効期限ルールは設定しないでください。

S3 backend では multipart upload を使用するため、アップロード途中でプロセスが中断すると未完了のパートが残ることがあります。バケットには、運用上の最大アップロード時間より十分長い期間を指定して、未完了の multipart upload を自動中止する lifecycle rule を設定してください。`fs` backend では、オープン時に 1 日以上更新されていない一時ファイルが自動的にクリーンアップされます（これは一時ファイルの掃除であり、バックアップの代わりにはなりません）。

動作確認では、まず Worker 停止中に Console から既知ファイルのアップロードとダウンロードを試し、続いて 1 つの Worker を動かしてドライブアクセスと添付ファイルの送受信を確認します。`AccessDenied` が出る場合は IAM 主体とバケット権限、`fs` で書き込みに失敗する場合は mount 状態・uid 10001 の権限・ディスク空き容量、既存ファイルが見つからない場合はバケット・region・prefix およびコピー結果をそれぞれ確認してください。あわせて[バックアップ](../backup-and-restore/)と [2.0 への更新](../upgrade-to-2/)も参照してください。
