---
title: バックアップとリストア
description: PostgreSQL、ファイルストア、永続 Agent Home、デプロイの秘密情報を一緒にバックアップして検証します。
section: Guides
order: 315
---

PostgreSQL、control plane のファイルストア、各 Agent の永続 Home を一緒にバックアップします。デプロイの秘密情報は別の secret manager に保存します。Worker インスタンスとキャッシュは再作成できますが、Home は復元が必要です。

## バックアップ対象

| データ | 内容 | 取得元 |
|---|---|---|
| PostgreSQL | Principal、Session、Job、provider 設定、暗号化認証情報、generation、ストレージ参照 | `pg_dump -Fc` |
| ファイルストア | 添付ファイル、公開ファイル、Skill、Automation スクリプト | Compose `files_data`、PVC、S3 バケット |
| Agent Home | workspace、ユーザーパッケージ、`/workspace/.codex` のスレッド | provider の volume、共有ディレクトリ、Drive、EFS、Cloudflare R2 バックアップ |
| デプロイの秘密情報 | `ANKOLE_SECRET_BASE` と起動時の認証情報 | 別の secret manager |

`/var/cache/ankole` とイメージは再作成できます。Home はキャッシュではありません。Docker Home のバックアップは別のホストにも保存します。Cloudflare は R2 バックアップと一致する `storage_ref` をデータベースに含める必要があります。強制停止では最後のバックアップ後の書き込みが失われる場合があります。

## 整合性のあるバックアップ

1. 新しい要求と定期処理を止め、Agent を無効にし、実行中の作業の終了を待ちます。Worker の終了中は control plane を動かしたままにします。
2. 各プラットフォームの通常の停止または削除操作で、一時停止中を含む Worker インスタンスを終了します。強制削除、Kubernetes の猶予 0、Agent の削除は使いません。control plane が不在を確認し、現在のストレージ参照を保存するまで待ちます。Cloudflare はディレクトリバックアップの完了も確認します。未確定の作成要求がある場合は、確定するまで続行できません。
3. control plane を停止します。これだけでは別管理の Worker は停止しません。Home への書き込みがないことを確認します。
4. PostgreSQL を起動したままアーカイブを取得します。書き込みを止めた状態でファイルストアと全 Home を保存します。volume 名、provider 設定、Agent UID、所有者、権限を保持します。
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

起動前に対応するファイルストア、Home、provider の配置、元の `ANKOLE_SECRET_BASE` を復元します。このキーは provider 認証情報と未確定 generation の再試行認証情報を復号します。新しいキーの生成だけでは復旧できません。

元のストレージ構成と uid 1000 の所有権を保持します。Agent の provider、provider の配置と永続ストレージ設定は変更できません。別の構成への移動には移行計画が必要です。

復旧演習ではプラットフォームの復元リソースを本番から隔離します。独立した 2 つの control plane が同じ Home を管理してはいけません。未確定の結果を避けるために generation を消去しないでください。

既知の workspace ファイルとドライブファイル、Home からの Job 再開、実際の Turn を検証します。構成や手順が変わったら再度演習します。[ディザスタリカバリ](../disaster-recovery/)と [Worker](../worker-management/)も参照してください。
