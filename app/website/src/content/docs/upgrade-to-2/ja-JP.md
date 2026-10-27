---
title: 1.0 から 2.0 へのアップグレード
description: 1.x サイトのデータベース、Worker、Agent Home、ドライブを 2.0 へ移行し、正常に動作・復元できることを検証する手順を説明します。
section: Guides
order: 313
---

このガイドは、Ankole 1.0（または後続の 1.x リリース）から 2.0 へ移行するセルフホスト環境向けの手順書です。メンテナンスウィンドウを確保し、旧バージョンのすべての書き込みプロセスを停止してから、新しいマイグレーションを実行してください。一度適用したデータベースマイグレーションは、コンテナイメージを旧バージョンに戻すだけでは取り消せません。

本番環境をアップグレードする前に、必ず隔離された検証環境でバックアップデータを使って同じ移行手順をリハーサルしてください（特に初期の 1.x バージョン、独自構成のデプロイ、またはスキーマに手を加えている環境では必須です）。

## 変更点

| 旧 1.x の構成 | 2.0 の構成 | 必要な運用作業 |
| --- | --- | --- |
| プール型 Worker と共有 `/agents` | Agent ごとの専用 Worker と専用 `/workspace` | Home を移行または引き継ぎ、WorkerProvider を割り当てる |
| Home 内の Skill と Automation スクリプト | コントロールプレーンドライブ上の `skills/` と `automation/` | 1 回かぎりのファイルインポートを実行する |
| Worker 上の一時的な Codex 状態 | スレッドは `/workspace/.codex`、再構築可能なキャッシュは `/var/cache/ankole/codex` | Home を保持しつつ、別途キャッシュ用ディスクを用意する |
| インプロセス実行と 2 イメージ構成 | 外部のステートレス `ankole-function-runtime`（同一バージョンの 3 イメージ：`control-plane`、`worker`、`function-runtime`） | `ANKOLE_FUNCTION_RUNTIME_TOKEN` を追加し、対応する 3 イメージすべてを同時に更新する |
| テナント所有権のないデータと設定 | 既存データは `default` テナントへ集約、Pod / Base ストレージは **PostgreSQL 18+** 必須（任意の `BASE_DB_URLS` 専用シャード対応） | PostgreSQL 18+ へ更新したうえで、元の暗号鍵を使ってスキーマと暗号化設定を移行する |
| `LocalPassword` と単一管理者グループ | 100% パスワードレス認証（`SiteCredential` `email_otp` + エンタープライズ SSO）およびテナント単位の `pod_admin` と `siteadmin` の分離 | 資格情報プリフライトを通過させ、SMTP（`authn.email.mail` または `mix ankole.authn.mail.put`）または SSO を設定して Pod 管理者を検証する |
| `/console` の管理 Console | `/site-admin-console`（または `ANKOLE_SITE_ADMIN_CONSOLE_PATH`）のサイト管理 Console | ブックマークと Ingress ルールを更新する |

すでに専用 Worker やドライブ構成を導入済みの後期 1.x サイトでは、未適用の手順だけを実施してください。既存の Home やドライブを誤って空のストレージで上書きしないよう注意してください。

## 事前準備

1. 現行バージョンと移行先バージョン、イメージの digest、Compose プロジェクト名または Helm リリース名、インストール識別子、ボリューム / PVC 名、および Provider 設定を控えておきます。**3 つのイメージすべて**（`control-plane`、`worker`、`function-runtime`）を同一のソースリビジョンに揃える必要があります（公式の `control-plane` イメージには、対応する Worker イメージ参照が組み込まれています）。
2. 元の `ANKOLE_SECRET_BASE`、データベース認証情報、デプロイ設定をそのまま維持し、まだ設定していない場合は個別のランダムな 16 進文字列として `RELEASE_COOKIE` と `ANKOLE_FUNCTION_RUNTIME_TOKEN` を生成して追加します。既存の暗号化設定を復号できなくなるため、`ANKOLE_SECRET_BASE` は絶対に再生成しないでください。
3. 旧環境を停止する前に、Ecto マイグレーションを安全停止させる以下のプリフライト条件を旧環境上で点検・解消しておきます。
   - **予約済みグループ名の衝突（`siteadmin` と `pod_admin`）：** 特権テナントに独自作成した `siteadmin` グループがある場合、またはいずれかのテナントに独自作成した `pod_admin` グループ（特に `computed` グループ）がある場合は、アップグレード前に別名へ変更してください。2.0 ではどちらもシステム予約名となっており、名前が衝突するとマイグレーションが中断します。なお、移行後に有効な管理者が 1 人もいないテナントが生じた場合は、`mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG` で復旧できます（`--tenant` を省略すると特権テナントの `siteadmin` を復旧します）。
   - **パスワードレス資格情報プリフライト（`Ankole.CredentialUpgrade.preflight!/1`）：** 破壊的な資格情報変換の前に読み取り専用の事前検査が走り、オフボーディングされていない Human（`active` または `suspended`）のログインメールアドレスが空または未設定の場合、同一テナント内の 2 つの保持対象 Principal で正規化後のログインメールアドレスが重複している場合、または 1 つの Principal に複数のログインメールアドレスが紐付いている場合にマイグレーションを中断します。エラーで報告されたレコードを 1.x 側で修正してから再実行してください。移行時にはブラウザーのパスワードセッション証明が失効します（単一の元証明に一意に対応するオフライン OIDC セッションは引き継がれますが、それ以外は再認可が必要です）。`LocalPassword` を利用していたサイトでは、移行後の `email_otp` ユーザーがサインインできるよう、必ず SMTP（Console の `authn.email.mail`、または `mix ankole.authn.mail.put FILE.json` / `Ankole.Release.put_authn_mail/1`）またはエンタープライズ SSO を設定してください。
   - **Console 権限付与における CEL `resource` 変数チェック：** `site_console:*` または `tenant_console:*` へ変換される旧 Console 向け grant の CEL `condition` では、`resource` 変数を参照できません。カスタムの Console grant を点検し、アップグレード前に `resource` への参照を取り除いてください。
4. 新規リクエストの受付とスケジュール実行を止め、全 Agent を無効化して進行中の作業が完了するのを待ちます。休止中のものも含めて旧 Worker をすべて正常停止させたあと、旧コントロールプレーンの全レプリカを停止します（作業停止のために Agent 自体を削除しないでください）。
5. データベースサーバーが **PostgreSQL 18+**（`server_version_num >= 180000`、`shared_preload_libraries` に `pg_search` を含み、`pg_search` と `vector` 拡張が利用可能）で稼働していることを確認します。PostgreSQL（設定済みの専用 `BASE_DB_URLS` シャードデータベースを含む）、既存のファイルストレージ、全 Agent の Home、およびデプロイのシークレット一式をバックアップし、ログイン・テナントメンバーシップ・OIDC の動作確認がすべて完了するまで保全してください。事前にバックアップの複製環境で 2.0 マイグレーションを試走し、所要時間を見積もっておきます。なお、Docker Compose での Home コピーには、旧ボリュームの使用量以上の空きディスク容量が追加で必要です。詳しくは [バックアップと復元](../backup-and-restore/) を参照してください。

マイグレーション処理では、テナントごとの Identity Provider 設定の再暗号化、旧 Slack / Teams 共有設定の分割、および各チャット基盤のアプリケーション ID 解決が行われます。そのため、元の暗号鍵、有効な認証情報、および各外部プラットフォームへのネットワーク到達性が必要です。途中で失敗した場合は、ログに出力された該当設定を修正して再実行してください。暗号文データを手動で別スコープへコピーしないでください。

## Docker Compose

移行先バージョンの [Compose ファイル一式](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)（`compose.yaml`、`worker-providers.yaml`、`migrate-agent-homes.sh`）を使用します。元の `.env` と Compose プロジェクト名を維持したまま、`ANKOLE_CONTROL_PLANE_IMAGE` と `ANKOLE_FUNCTION_RUNTIME_IMAGE` を移行先リリースの一致するイメージタグまたは digest に固定します（対応する Worker イメージは `control-plane` イメージ側で指定されています）。あわせて `ANKOLE_DOCKER_GID` を設定し、元の `ANKOLE_WORKER_INSTALLATION` をそのまま維持します。

以下のコマンド例は公式のローカル `fs` ドライブ構成を前提としています。S3 を利用する場合は [ドライブ設定](../drive-storage/) の override ファイルを用意し、インポート実行時も含めすべての `docker compose` コマンドに同じ `-f` オプションを付けてください。

`.env` に `RELEASE_COOKIE` または `ANKOLE_FUNCTION_RUNTIME_TOKEN` が未設定の場合は追記します。

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

初回起動時の Provider シード設定では `legacy_agents: true` を指定し、`provider_id` を Home 移行サービスの `WORKER_PROVIDER` と一致させます（公式ファイルでは `docker` です）。このシードは Provider テーブルが空のときに一度だけ取り込まれるため、取り込み後に YAML ファイルを書き換えても保存済みの Provider 設定は更新されません。

2.0 には **PostgreSQL 18+**（`pg_search` 0.25.11 および `vector`）が必須です。既存データベースが PostgreSQL 18 未満の場合は、先に PostgreSQL のメジャーバージョンアップグレードを済ませてから `pg_search` 拡張を更新してください。

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

`migrate` サービスは DB スキーマと設定データを移行し、`migrate-agent-homes` サービスは旧共有ボリュームを参照しているコンテナを停止したうえで、実在する各 Agent の Home を専用ボリュームへコピーして所有者を `uid 1000` に変更します。この両方が正常完了してからコントロールプレーン本体が起動します。完了マーカーが記録されるため、再実行しても移行済みディレクトリが上書きされることはありません（旧ボリュームが存在しない環境ではコピーを行わず正常終了します）。

この段階ではまだ Agent を無効のままにしておきます。旧バージョンでドライブ機能を使っていなかった場合は、旧ボリュームに読み取り権限を付与してファイルインポートを実行します。以下は既定プロジェクト名の例なので、独自プロジェクト名を使っている場合は `ankole_agents_data` を実際の旧ボリューム名に置き換えてください。

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

このインポート処理では、Skill、Automation スクリプト、および未送信の旧 Outbox 添付ファイルがドライブへコピーされ、既存のドライブパスが上書きされることはありません。それ以外の一般ユーザーファイルや Session・Job の作業ディレクトリはそのまま Home 内に残ります。出力された実行レポートを保存し、`Skipped` になった項目や `main.ts` が欠けている Job があれば修正して再実行してください。ファイルの確認とリストア検証がすべて終わるまでは、旧ボリュームを削除せずに残しておきます。

## Kubernetes / Helm

1. 旧バージョンのコントロールプレーンとプール型 Worker の Deployment をレプリカ数 `0` にスケールダウンし、旧 Pod がすべて終了するまで待ちます。強制削除や `--grace-period=0` は使わないでください。
2. 外部または同梱のデータベースが **PostgreSQL 18+** で稼働していることを確認します。`secrets.existingSecret`（`ankole-bootstrap`）を使っている場合は、`helm upgrade` の実行前に `ANKOLE_SECRET_BASE` と `DATABASE_URL` に加え、`RELEASE_COOKIE` と `ANKOLE_FUNCTION_RUNTIME_TOKEN` の両方が登録されていることを確認します。

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   （`ankole-bootstrap` 内でまだ未設定のキーに対してのみ実行してください。）
3. 旧共有 Home の PVC をそのまま残し、`worker.agents.persistence.existingClaim` に指定します。元の `worker.installation` と Helm リリース名も変更せず維持してください。また、同梱 PostgreSQL のデータがボリューム直下に置かれている環境では、元の `postgresql.pgdata`（`/var/lib/pgsql/18/data`）を維持してください（別パスに変えると空のデータベースとして初期化されて見えることがあります）。
4. 新しいコントロールプレーンを起動する前に、Home ボリュームの所有者とパーミッションを整えます。以下のコマンドは Pod 内の root ユーザーが `chown` を実行できるストレージ向けの例です（`OLD_AGENTS_PVC` は実際の PVC 名に置き換えてください）。

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

既定で root-squash が有効になっている NFS 環境では、Pod 内からこの `chown` を実行できません。NFS サーバー側で直接所有者と権限を変更して Worker root からの書き込みと所有者変更を許可するか、すべてのアクセスを `uid/gid 1000` にマッピングしてください。なお、`uid/gid 1000` の EFS Access Point を使っている場合は所有者変換は不要です。詳しくは [WorkerProvider とキャッシュディスク](../worker-providers/) を参照してください。

続いて、`values-production.yaml` にバージョンを揃えた `controlPlane.image` と `functionRuntime.image` の digest（Worker イメージを明示的に上書きする場合のみ、同一リビジョンの `worker.image` も指定）、[ドライブバックエンド](../drive-storage/)、および旧 PVC を設定してアップグレードを実行します。

以下のコマンドは Namespace とリリース名がともに `ankole` で、`fullnameOverride: ankole` を指定している環境を前提としています。

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

Deployment は `Recreate` 戦略で更新され、新しい Pod の起動前に `db-migrate` init コンテナがマイグレーションを実行します。ファイルインポートが完了するまでは Agent を無効のままにしておいてください。出力レポートを確認したら、`files.importAgentHomeClaim` 指定を外してもう一度 `helm upgrade` を実行し、一時マウントを解除します（Worker 側が参照する旧 Home PVC 自体は引き続き必要です）。独自のリリース名、Namespace、Deployment 名を使っている場合は適宜コマンドを読み替えてください。全パラメータの一覧は [Helm ガイド](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md) を参照してください。

## 検証と復旧

- Console で `default` テナントを開き、既存の Agent、Identity Provider、シグナルルーティングルール（signal binding）、Job が揃っていることを確認します。既存のすべての Agent に WorkerProvider が割り当てられている必要があります（既定 Provider 設定は新規作成時の初期選択にのみ使われます）。
- まず 1 体の Agent だけを有効化し、実際のファイル操作と Job 実行を試します。旧 Home の引き継ぎ、Codex スレッドの復元、Skill、Automation スクリプト、ドライブのアップロード・ダウンロード、添付ファイルの送信がすべて正常に動くことを確認してから、残りの Agent とスケジュール処理を再開してください。
- マイグレーションが失敗した場合は、旧コントロールプレーンを停止したまま、Compose の `migrate` または Kubernetes の `db-migrate` ログを確認します。暗号鍵、認証情報、予約グループ名の衝突、ストレージ権限などの原因を解消し、同じ移行先バージョンで再実行してください。
- インポートレポートに表示された「削除済み Agent」の残存ディレクトリから勝手に新しい Agent が作られることはありません。不要であることを確認したうえで旧ディレクトリや旧ボリュームを整理してください。
- 万が一ロールバックする場合は、新しいコントロールプレーン、`ankole-function-runtime`、および Worker をすべて停止し、アップグレード前に取得した PostgreSQL バックアップ（設定済みの `BASE_DB_URLS` シャードを含む）、ファイルストレージ、Home、設定、元の暗号鍵を一式まとめてリストアしてから、対応する旧バージョンのイメージを起動します。`helm rollback` やコンテナイメージの差し戻しだけでは、破壊的なパスワードレス資格情報変換や DB スキーマ変更を元に戻すことはできず、アップグレード後に発生した書き込みも別途退避しないかぎり保持されません。

アップグレード後の定常運用については、[Worker](../worker-management/)、[ドライブ設定](../drive-storage/)、および [災害復旧](../disaster-recovery/) を参照してください。
