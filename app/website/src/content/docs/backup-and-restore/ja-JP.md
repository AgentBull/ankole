---
title: バックアップとリストア
description: PostgreSQL、ファイルストア、永続 Agent Home、デプロイの秘密情報を一緒にバックアップして検証します。
section: Guides
order: 315
---

PostgreSQL（control-plane データベースおよび `BASE_DB_URLS` のすべての物理 Base シャードデータベース）、オブジェクトストア（control plane のファイルストア）、各 Agent の永続 Home を一緒にバックアップします。デプロイの設定と秘密情報は別の secret manager に保存します。Worker インスタンス、`ankole-function-runtime`、および `/var/cache/ankole` は再作成できますが、永続 Home とデータベースは復元が必要です。

## バックアップ対象

| データ | 内容 | 取得元 |
|---|---|---|
| Control-plane PostgreSQL | Principal、Session、Job、Pod のメタデータとドキュメント、provider 設定、暗号化認証情報、generation、ストレージ参照 | `pg_dump -Fc` または PITR |
| 物理 Base シャード（`BASE_DB_URLS`） | テナントの物理 Base テーブル行（`BASE_DB_URLS` 未設定の単一 DB 構成では Base テーブルも control-plane DB 内にあり、1 回のアトミックな `pg_dump` で両方を含む） | 各シャード DB の `pg_dump -Fc` または PITR |
| オブジェクトストア（ファイルストア） | Pod の `file` ページ、Pod と会話の添付ファイル、コンパイル済み Applet バンドル、公開ファイル、Skill、Automation スクリプト | Compose `files_data`、PVC、S3 バケット |
| Agent Home | workspace、ユーザーパッケージ、`/workspace/.codex` のスレッド | provider の volume、共有ディレクトリ、Drive、EFS、Cloudflare R2 バックアップ |
| デプロイ設定と秘密情報 | `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`BASE_DB_URLS`、および起動時の認証情報 | 別の secret manager |

`/var/cache/ankole` とイメージは再作成できます。Home はキャッシュではありません。Docker Home のバックアップは別のホストにも保存します。Cloudflare は R2 バックアップと一致する `storage_ref` をデータベースに含める必要があります。強制停止では最後のバックアップ後の書き込みが失われる場合があります。

## 整合性のあるバックアップ

1. 新しい要求と定期処理を止め、Agent を無効にし、実行中の作業の終了を待ちます。Worker の終了中は control plane を動かしたままにします。
2. 各プラットフォームの通常の停止または削除操作で、一時停止中を含む Worker インスタンスを終了します。強制削除、Kubernetes の猶予 0、Agent の削除は使いません。control plane が不在を確認し、現在のストレージ参照を保存するまで待ちます。Cloudflare はディレクトリバックアップの完了も確認します。未確定の作成要求がある場合は、確定するまで続行できません。
3. control plane を停止します。これだけでは別管理の Worker は停止しません。Home への書き込みがないことを確認します。
4. PostgreSQL を起動したままアーカイブを取得します。単一 DB 構成（`BASE_DB_URLS` 未設定）では 1 回の `pg_dump` で control plane と Base テーブルをアトミックに取得できます。マルチシャード構成（`BASE_DB_URLS` 設定時）では、control-plane データベースとすべての物理 Base シャードデータベースをバックアップします。書き込みを止めた状態でオブジェクトストアと全 Home を保存します。volume 名、シャード ID、provider 設定、Agent UID、所有者、権限を保持します。
5. control plane を起動し、Agent を有効にして既知の Home ファイルとドライブファイルを確認します。

Compose のデータベースバックアップ:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

volume とバケットにはストレージのバックアップ機能を使います。アップグレードや破壊的な保守の前にも取得します。イメージ変更ではデータベース migration を戻せません。

## 復元と検証

復元中は全 control plane と Worker を停止します。対象データベースで次を実行します。

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

`BASE_DB_URLS` に含まれるすべての物理 Base シャードデータベースも復元します。マルチシャード構成でポイントインタイムリカバリ（PITR）を使用する場合、各 Base シャードの復旧タイムスタンプは control-plane データベースの復旧タイムスタンプ以上（`>=`）にする必要があります。

起動前に対応するオブジェクトストア、Home、provider の配置、`BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、元の `ANKOLE_SECRET_BASE` を復元します。`ANKOLE_SECRET_BASE` は provider 認証情報と未確定 generation の再試行認証情報を復号します。新しいキーの生成だけでは復旧できません。

元のストレージ構成と uid 1000 の所有権を保持します。Agent の provider、provider の配置と永続ストレージ設定は変更できません。別の構成への移動には移行計画が必要です。

復旧演習ではプラットフォームの復元リソースを本番から隔離します。独立した 2 つの control plane が同じ Home を管理してはいけません。未確定の結果を避けるために generation を消去しないでください。

既知の workspace ファイルとドライブファイル、Home からの Job 再開、実際の Turn を検証します。構成や手順が変わったら再度演習します。[ディザスタリカバリ](../disaster-recovery/)と [Worker](../worker-management/)も参照してください。
