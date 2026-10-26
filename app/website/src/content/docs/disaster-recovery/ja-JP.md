---
title: ディザスタリカバリ
description: Ankole デプロイメントの復旧手順 — PostgreSQL、Base シャードデータベース、ファイルストア、Agent Home、Function Runtime、秘密情報の復元と復旧演習。
section: Guides
order: 320
---

コントロールプレーンの PostgreSQL データベース、専用 Pod Base シャードデータベース（`BASE_DB_URLS` を構成している場合）、ファイルストア、永続 Agent Home、`ankole-function-runtime`、および元のデプロイ秘密情報を 1 つのデプロイメントとしてまとめて復元します。保全対象のデータと整合バックアップ手順は[バックアップガイド](../backup-and-restore/)を参照してください。

## 復旧前

旧コントロールプレーンと Worker が、復元後の Home やデータベースに書き込めないことを確認します。通信断だけでは Worker 停止の証明になりません。一時停止中のインスタンスや結果不明の作成要求も対象です。未確定の generation とその認証情報は PostgreSQL に保持し、プラットフォームが確定結果を返すまで同じ generation を使います。

リハーサルは隔離されたプラットフォームリソースに復元します。本番 provider の配置が残ったデータベースのコピーは、本番インスタンスを操作してしまいます。provider 間やストレージ構成間の自動移行はありません。

## 復旧手順

1. コントロールプレーンを停止した状態で代替インフラを準備し、provider の配置、`BASE_DB_URLS` のシャード ID（`ankole_sharding`）、永続ストレージ構成を保持します。同一リリースのステートレスな `ankole-function-runtime` サービスを準備し、空の volume が作られる前に Docker Home volume を復元します。
2. コントロールプレーンの PostgreSQL、`BASE_DB_URLS` のすべての専用 Base シャードデータベース（構成時）、対応するファイルストア、およびすべての永続 Home を[バックアップとリストア](../backup-and-restore/)の順序で復元します。専用 Base シャードをポイントインタイムリカバリ（PITR）で復元する場合は、コントロールプレーン側で物理テーブルと記録された Base テーブルがシャード側で欠落しないよう、**すべての Base シャードデータベースの復旧タイムスタンプをコントロールプレーンデータベースの復旧タイムスタンプ以上（`>=`）**に設定し、PostgreSQL のロケール・照合順序および `public._ankole_shard` のシャード ID を維持します。Agent UID、volume 名、ファイル所有者、権限を保持します。
3. シークレットマネージャーから元の `ANKOLE_SECRET_BASE` を復元します。これは provider の秘密情報と未確定 generation の認証情報の復号に必要です。紛失した場合は作業を止め、別途の認証情報復旧計画を立ててください。新しい provider 認証情報の再入力だけでは generation の認証情報は復元できません。
4. 残りの起動用秘密情報と接続先（`DATABASE_URL`、専用シャード利用時の `BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_URL`、および共有トークン `ANKOLE_FUNCTION_RUNTIME_TOKEN`）を設定し、`ankole-function-runtime` とコントロールプレーンを起動して通常の調整処理に実際のプラットフォーム状態を確認させます。見かけ上の状態を正常にするために generation やインスタンス参照を消去しないでください。未確定の結果は `starting` または `deleting` に留まり、原因は `last_error` に記録されます。
5. 復元した Agent を有効化します。既知の Home ファイル、ドライブまたは Pod ファイル、Pod Base テーブルを読み取り、Background Job を再開して実際の Turn を実行します。トラフィックを切り替える前に、旧デプロイが停止したままであることを再確認します。

## 復旧範囲

PostgreSQL と Base シャードデータベースは永続的な作業状態と Pod Base データを復元し、Home はワークスペースと Codex スレッドファイルを復元します。SQLite キャッシュは再構築可能であり、`ankole-function-runtime` は永続状態を持ちません。バックアップ後の書き込み、プロセスメモリ、実行中のモデル要求や関数呼び出しはバックアップに含まれません。

Docker のホストが失われた場合、ローカル volume の復旧には外部バックアップが必要です。Cloudflare は R2 バックアップとデータベース参照の両方が必要であり、強制停止すると最終バックアップ以降の変更が失われる場合があります。[Worker](../worker-management/) の制限も確認してください。

計画的なホスト移行では、まず書き込みを停止し、PostgreSQL、Base シャード、ファイルストア、Agent Home の最終整合バックアップを取得します。演習では隔離リソース上で同じ手順とユーザーフローを検証し、実際の復旧時点と所要時間を記録します。Base シャード、Home、または `ANKOLE_SECRET_BASE` を省いた演習は完全復旧の証明になりません。
