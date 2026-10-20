---
title: 1.0 から 2.0 へのアップグレード
description: 1.x サイトのデータベース、Worker、Agent Home、ドライブを 2.0 に移行し、復元を検証します。
section: Guides
order: 313
---

このガイドは、1.0 または後続の 1.x から 2.0 に移行するセルフホストサイト向けです。保守時間を確保し、旧バージョンの全書き込みプロセスを停止してから新しい migration を実行します。イメージを戻してもデータベース migration は取り消せません。

リポジトリの Compose アップグレードテストは、最後のプール型 Worker リリース `v1.6.18-rc.1` を起点とします。それより前の 1.x、独自デプロイ、変更済み schema は、隔離環境でバックアップを使って同じ手順を事前に検証してください。全 1.x 起点の検証を意味するテストではありません。

## 変更点

| 旧 1.x の構成 | 2.0 の構成 | 運用作業 |
| --- | --- | --- |
| プール型 Worker と共有 `/agents` | Agent ごとに Worker と専用 `/workspace` | Home を移行または引き継ぎ、WorkerProvider を割り当てる |
| Home 内の Skill と Automation スクリプト | control plane ドライブの `skills/` と `automation/` | 一度限りのファイルインポートを実行する |
| Worker の一時的な Codex 状態 | スレッドは `/workspace/.codex`、再構築可能なキャッシュは `/var/cache/ankole/codex` | Home を保持し、別のキャッシュディスクを用意する |
| tenant 所有権のないデータと設定 | 既存データは `default` tenant、サイト設定と tenant 設定を分離 | 元の鍵で schema と暗号化設定を移行する |

既に専用 Worker やドライブを使う 1.x サイトでは、必要な手順だけを実行します。既存 Home やドライブを空のストレージに置き換えないでください。

## 事前準備

1. 現行と移行先のバージョン、イメージ digest、Compose project または Helm release 名、インストール識別子、volume/PVC 名、provider 設定を記録します。control plane と Worker は同じソース revision を使います。公式 control plane イメージには対応する Worker 参照が含まれます。
2. 元の `ANKOLE_SECRET_BASE`、データベース認証情報、デプロイ設定を保持します。新しいデプロイには独自の `RELEASE_COOKIE` も必要です。既存設定を復号する `ANKOLE_SECRET_BASE` を再生成しないでください。
3. 旧 Console に独自の `siteadmin` グループがある場合は、先に名前を変更します。2.0 では予約名となり、衝突すると migration が停止します。
4. 新しい要求と定期処理を停止し、Agent を無効にして実行中の作業を待ちます。休止中を含む全旧 Worker を通常停止してから、全旧 control plane レプリカを停止します。停止のために Agent を削除しないでください。
5. PostgreSQL、既存ファイルストレージ、全 Agent Home、デプロイの秘密情報をまとめてバックアップし、復元できることを確認します。Compose の Home コピーには旧 volume 使用量以上の追加空き容量が必要です。[バックアップと復元](../backup-and-restore/)を参照してください。

アップグレードは tenant の identity provider 設定を再暗号化し、旧 Slack/Teams 共有設定を分割し、プラットフォームのアプリケーション ID を解決します。元の鍵、有効な認証情報、各プラットフォームへの接続が必要です。失敗時はログに示された設定を修正して再実行します。暗号文を新しい scope に直接コピーしないでください。

## Docker Compose

移行先バージョンの [Compose ファイル](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)を使用します。`compose.yaml`、`worker-providers.yaml`、`migrate-agent-homes.sh` が必要です。元の `.env` と project 名を保持し、`ANKOLE_CONTROL_PLANE_IMAGE` を移行先 digest に固定します。`ANKOLE_DOCKER_GID` を設定し、元の `ANKOLE_WORKER_INSTALLATION` を保持します。

例は公式 `fs` 設定です。S3 は [ドライブ設定](../drive-storage/)の override を準備し、インポートを含む全 Compose コマンドで同じ `-f` を指定します。

`.env` に `RELEASE_COOKIE` がない場合だけ追加します。

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

初回 provider seed は `legacy_agents: true` を指定し、`provider_id` を Home 移行サービスの `WORKER_PROVIDER` と一致させます。公式ファイルは `docker` です。seed は provider テーブルが空の場合だけ取り込みます。以後の YAML 編集は保存済み provider を更新しません。

現在のデプロイは `pg_search` 0.25.11 を使います。次の拡張更新は `pg_search` が導入済みで PostgreSQL メジャーバージョンが互換の場合に使います。メジャーバージョンが異なる場合はデータベース更新を先に完了してください。

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps -a migrate migrate-agent-homes
docker compose logs migrate migrate-agent-homes
```

`migrate` は schema と設定データを移行します。`migrate-agent-homes` は旧共有 volume を使うコンテナを停止し、存在する Agent の Home を専用 volume にコピーして uid 1000 に変更します。両方が成功してから control plane が起動します。完了マーカーにより再実行で完了済みディレクトリを上書きしません。旧 volume がない場合はコピーせず完了します。

Agent は無効のままにします。旧バージョンにドライブがない場合、旧 volume をインポート処理から読み取り可能にし、ファイルを取り込みます。以下は既定 project の例です。独自 project では `ankole_agents_data` を元の volume 名に置き換えます。

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

インポートは Skill、Automation スクリプト、未送信の旧 Outbox 添付をコピーし、既存ドライブパスを上書きしません。他のユーザーファイル、Session と Job の作業領域は Home に残ります。レポートを保存し、`Skipped` や `main.ts` のない Job を修正して再実行します。ファイル検証と復元演習が成功するまで旧 volume を保持してください。

## Kubernetes / Helm

1. 旧 control plane とプール型 Worker Deployment をゼロに縮小し、旧 Pod が全て消えるまで待ちます。強制削除や `--grace-period=0` は使いません。
2. 旧共有 Home PVC を保持し、`worker.agents.persistence.existingClaim` に指定します。元の `worker.installation` と release 名を保持します。旧データベースが volume 直下にある場合は元の `postgresql.pgdata` を維持します。新しいディレクトリに変えると空のデータベースに見える場合があります。
3. 新 control plane 起動前に Home の所有権と権限を準備します。以下は Pod root が `chown` を実行できるストレージ向けです。`OLD_AGENTS_PVC` を実際の名前に置き換えます。

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

既定の root-squash NFS では Pod からこの `chown` を実行できません。NFS サーバーでファイルを準備し、Worker root の書き込みと所有権変更を許可するか、全アクセスを uid/gid 1000 にマッピングします。uid/gid 1000 の EFS access point を使うファイルには所有権変換が不要です。[WorkerProvider とキャッシュディスク](../worker-providers/)を参照してください。

`values-production.yaml` に移行先 control plane digest、[ドライブバックエンド](../drive-storage/)、旧 PVC を設定して実行します。

コマンドは namespace と release 名 `ankole`、`fullnameOverride: ankole` を前提とします。

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

Deployment は `Recreate` を使い、新 Pod の `db-migrate` init container が先に migration を実行します。インポート完了まで Agent は無効にします。レポート確認後、`files.importAgentHomeClaim` を削除して再度アップグレードします。Worker 用の旧 Home PVC は引き続き必要です。独自 release、namespace、Deployment 名はコマンドを調整してください。[Helm ガイド](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md)に全パラメータがあります。

## 検証と復旧

- Console の `default` tenant で旧 Agent、identity provider、signal binding、Job を確認します。既存 Agent に WorkerProvider が割り当てられている必要があります。既定 provider は新 Agent の選択にのみ使います。
- Agent を一つ有効にし、実際のファイル操作と Job を実行します。旧 Home、Codex スレッド復元、Skill、Automation スクリプト、ドライブのアップロード・ダウンロード、添付送信を確認してから他の Agent と定期処理を戻します。
- migration 失敗時は旧 control plane を停止したまま、Compose `migrate` または Kubernetes `db-migrate` のログを確認します。鍵、認証情報、名前衝突、権限を修正し、同じバージョンで再実行します。
- レポートにある削除済み Agent のディレクトリから新 Agent は作成されません。不要と確認してから旧ディレクトリや volume を削除します。
- ロールバックでは全新 control plane と Worker を停止し、更新前の DB、ファイルストレージ、Home、設定、元の鍵をまとめて復元して対応する旧イメージを起動します。`helm rollback` やイメージ変更だけではデータ移行を取り消せず、別途保存していない更新後の書き込みも保持できません。

以後の運用は [Worker](../worker-management/)、[ドライブ設定](../drive-storage/)、[災害復旧](../disaster-recovery/)を参照してください。
