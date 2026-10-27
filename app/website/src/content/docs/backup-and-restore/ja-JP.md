---
title: バックアップとリストア
description: PostgreSQL、ファイルストア、永続 Agent Home、およびデプロイの秘密情報を一貫した手順でバックアップ・復元・検証する方法を説明します。
section: Guides
order: 315
---

バックアップでは、PostgreSQL（control-plane データベースおよび `BASE_DB_URLS` に含まれるすべての物理 Base シャードデータベース）、オブジェクトストア（control plane のファイルストア）、そして各 Agent の永続 Home を必ずセットで保護します。デプロイ環境の設定値と秘密情報は、別系統のシークレットマネージャーに保管してください。Worker インスタンス、`ankole-function-runtime`、および `/var/cache/ankole` はいつでも再作成できますが、永続 Home とデータベースはバックアップからの復元が不可欠です。

## バックアップ対象

| データ | 含まれる内容 | バックアップ元 |
|---|---|---|
| Control-plane PostgreSQL | Principal、Session、Job、Pod のメタデータとドキュメント、provider 設定、暗号化済み認証情報、generation、ストレージ参照 | `pg_dump -Fc` または PITR |
| 物理 Base シャード（`BASE_DB_URLS`） | テナントの物理 Base テーブル行（`BASE_DB_URLS` 未設定の単一 DB 構成では Base テーブルも control-plane DB 内に同居するため、1 回の `pg_dump` で両方をアトミックに取得可能） | 各シャード DB の `pg_dump -Fc` または PITR |
| オブジェクトストア（ファイルストア） | Pod の `file` ページ、Pod や会話の添付ファイル、コンパイル済み Applet バンドル、公開ファイル、インストール済み Skill、Automation スクリプト | Compose の `files_data`、PVC、または S3 バケット |
| Agent Home | 作業用 workspace、ユーザーパッケージ、`/workspace/.codex` 内のスレッド履歴 | provider のボリューム、共有ディレクトリ、Drive、EFS、または Cloudflare R2 バックアップ |
| デプロイ設定と秘密情報 | `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`BASE_DB_URLS`、および起動時の各種認証情報 | 別系統のシークレットマネージャー |

`/var/cache/ankole` やコンテナイメージは再生成できますが、Agent Home はキャッシュではありません。Docker ボリューム上の Home バックアップは、障害に備えて別ホストや外部ストレージにも退避してください。また、Cloudflare バックエンドを使用している場合は、R2 上のバックアップと一致する `storage_ref` がデータベース側に記録されている必要があります（強制停止が発生した場合は、最後のバックアップ以降の書き込みが失われることがあります）。

## 整合性のあるバックアップ

静止点を揃えた整合性のあるバックアップを取得するには、次の順序で作業します。

1. 新規リクエストの受付と定期ジョブを停止し、Agent を無効化して、進行中の作業が完了するのを待ちます。Worker を終了させる間、control plane はまだ稼働させたままにしてください。
2. 各プラットフォームの通常の停止または削除手順を使い、一時停止中のものを含めてすべての Worker インスタンスを終了させます（強制 kill、Kubernetes の猶予時間 `0` での削除、または Agent 自体の削除は行わないでください）。control plane が Worker の不在を確認し、最新のストレージ参照をデータベースへ保存し終えるまで待ちます。Cloudflare バックエンドでは、ディレクトリバックアップが完了していることも確認してください。未確定のインスタンス作成リクエストが残っている場合は、結果が確定するまで次の手順へ進まないでください。
3. control plane を停止します（control plane を止めただけでは外部プラットフォーム上の Worker は自動停止しないため、必ず手順 2 を先に行います）。すべての Agent Home への書き込みが完全に止まっていることを確認します。
4. PostgreSQL を稼働させたままダンプまたはアーカイブを取得します。単一 DB 構成（`BASE_DB_URLS` 未設定）では、1 回の `pg_dump` で control plane と Base テーブルの両方をアトミックに取得できます。マルチシャード構成（`BASE_DB_URLS` 設定時）では、control-plane データベースとすべての物理 Base シャードデータベースをバックアップします。あわせて、書き込み停止中のオブジェクトストアと全 Agent Home を保存し、ボリューム名、シャード ID、provider 設定、Agent UID、ファイル所有者、パーミッションを維持します。
5. バックアップ完了後、control plane を再起動して Agent を有効化し、既存の Home 内ファイルやドライブ上のファイルが正常に参照できることを確認します。

Docker Compose 環境でのデータベースバックアップ例:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

ボリュームや S3 バケットには各ストレージ基盤のスナップショット／バックアップ機能を使用します。バージョンアップや破壊的なメンテナンスの前にも必ずバックアップを取得してください。コンテナイメージだけを以前のバージョンに戻しても、適用済みのデータベースマイグレーションを巻き戻すことはできません。

## 復元と検証

リストア作業中は、すべての control plane と Worker を停止しておきます。対象のデータベースに対して次のコマンドでリストアを実行します。

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

`BASE_DB_URLS` に含まれるすべての物理 Base シャードデータベースも同様にリストアします。マルチシャード構成でポイントインタイムリカバリ（PITR）を使用する場合は、各 Base シャードの復旧目標時刻を control-plane データベースの復旧目標時刻以上（`>=`）に揃える必要があります。

control plane を起動する前に、対応する時点のオブジェクトストア、全 Agent Home、provider の配置設定、`BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、および元の `ANKOLE_SECRET_BASE` をすべて復元してください。`ANKOLE_SECRET_BASE` は保存済みの provider 認証情報や未確定 generation のリトライ用認証情報を復号するために必須であり、新しく別のキーを生成しても元のデータは復号できません。

ストレージ構成や `uid 1000` のファイル所有権も元の状態のまま維持します。リストア時に Agent の provider や配置先、永続ストレージ設定を別の構成へ書き換えることはできません（構成自体を変更したい場合は、リストアとは別に移行計画が必要です）。

また、復旧訓練を行う際は、リストア先のプラットフォームリソースを本番環境から完全に隔離してください。独立した 2 つの control plane が同じ Agent Home を同時に管理する状態は避け、未確定状態の処理結果を隠すために generation レコードを手動で消去するような操作も行わないでください。

起動後は、既知の workspace ファイルやドライブ上のファイルの読み取り、Home からの Background Agent Job の再開、および実際の会話 Turn が正常に動くことを検証します。インフラ構成や運用手順を変更した際は、あらためて復旧訓練を実施してください。あわせて[ディザスタリカバリ](../disaster-recovery/)および [Worker](../worker-management/) も参照してください。
