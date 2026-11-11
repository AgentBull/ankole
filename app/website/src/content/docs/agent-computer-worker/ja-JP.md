---
title: Agent Computer Worker
description: 環境ツール、Codex、永続 Home、control plane 置換後の復旧。
section: Developer guide
order: 108
---

Agent Computer Worker は、個々の Agent に割り当てられる専用コンピュータ環境です。Agent の作成時に、Ankole は provider の紐付けと `absent` 状態の Worker レコードを保存し、初回起動をバックグラウンドでキューに入れます。初回起動が完了し、アイドル状態の Worker が解放された後は、環境ツールや Codex Job の要求に応じて起動します。通常の質疑応答や control plane 内のツールは Worker を待たずに実行できます。

## 実行と所有権

Bun ベースの Worker は、シェルコマンド、ファイル操作やブラウザ操作のツール、Skills、MCP 呼び出し、および Codex Job を実行します。一方、メインの Agent ループ、入力完了やツール実行結果のコミット、最終返信の確定は control plane の `Ankole.Sessions` が担当し、永続 Response チェーンと hosted ツールは AIGateway が管理します。

起動時、control plane は Worker に対して `WORKER_ID`、RuntimeFabric の URL、世代（generation）ごとの認証情報、およびストレージ設定を渡します。Worker は担当する 1 つの Agent の処理だけを行い、子プロセスの環境変数からは認証情報を除外し、データベースにも直接接続しません。`root` スーパーバイザー（`ankole-worker-supervisor` と `root` 専用の `ankole-rclone` デーモン）が `/dev/fuse` と `SYS_ADMIN` を保持する目的は各実行のプライベートマウント・PID 名前空間の構築であり、コマンドや Codex の子プロセスはすべて空の Linux ケーパビリティ（`NoNewPrivs`、`sudo` なし）を持つ `uid 1000` / `gid 1000` へ降格して実行されます。

## WorkerProvider とライブ接続

Agent に割り当てられた `WorkerProvider`（`WorkerProviders`）によって、使用するプラットフォーム、インスタンス構成、ストレージが決まります。複数の Agent で同じ `WorkerProvider` を共有しても、プラットフォーム上では Agent ごとに専用のコンピュータが作成されます。アイドル状態が続くと、Agent Home のデータを保持したままインスタンスが削除または休止されます。設定やライフサイクルの詳細については、[WorkerProvider](../worker-management/) を参照してください。

起動した Worker は `/runtime-fabric/worker/websocket` に対して認証済み WebSocket 接続を 1 本確立し、専用の Phoenix Channel に参加します。環境ツールの呼び出しや実行結果、Codex の制御メッセージ、進捗通知はすべて RuntimeFabric の protobuf envelope で送受信されます。その際、control plane は generation と incarnation を検証し、すでに置き換えられた古い Worker からの接続を拒否します。なお、ファイル本体は 1 回限りの HTTP 中継 URL を経由して転送され、復旧に必要な永続データは PostgreSQL に記録されます。

## 操作の識別と復旧

環境作業の `RunRef` には Agent、Session、およびトリガーとなった入力が指定され、個々のツール呼び出しは Response ID と call ID で一意に識別されます。control plane 側で新しい Driver が立ち上がった場合は、既存の workspace の状態を確認し、実行中の呼び出しを引き継ぐか完了済みの結果を取得します。control plane との接続が一時的に切れても、Worker 上のコマンド実行はそのまま継続します。もし Worker プロセス自体が失われた場合は、再実行しても安全な呼び出しだけがリトライされ、結果が確定しない呼び出しには `interrupted` が返されます。

一方、Codex では Job ID と attempt を含む `JobTurnRef` を使用します。`adopt` 操作を行うと、実行中の turn、スレッド、workspace がそのまま引き継がれます。Job のオーナーは attempt のフェンスを用いて終端状態の書き込みを検証し、適用済み入力 ID の完了処理を同一トランザクション内でコミットします。なお、Codex は Worker 内部に独自のモデルループを持っています。

開いている環境 workspace と実行中の Codex turn は、それぞれ Worker の実行枠（slot）を 1 つずつ消費します。メイン会話や Workflow におけるモデル呼び出しは Worker slot を消費しません。

## ファイルシステム契約

Agent Home は `/workspace` にマウントされる永続ストレージ（`/agents/<agent_uid>` は `/workspace` へのシンボリックリンク）であり、FUSE 対応の Worker では各実行のプライベートマウント名前空間内に統合ドライブが `/drive` としてマウントされます。

```text
/workspace/
├── .codex/
├── AGENTS.md
├── DESIGN.md
├── .ankole/turn-skills/<job-signal-id>/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/

/drive/
├── Public/        （読み書き）
├── MyDrive/       （読み書き、Personal Assistant オーナーの個人スペース）
├── AgentDrive/    （読み書き）
├── ChatDrive/     （読み書き、現在の会話スコープ）
├── Brain/         （読み取り専用、開示範囲でフィルタ）
├── Skills/        （読み取り専用）
├── AGENTS.md      （読み取り専用）
└── DESIGN.md      （読み取り専用）
```

`/drive` 配下では、`Ankole.Files.Vfs` が読み書き可能な `/drive/Public`、`/drive/MyDrive`（Personal Assistant として動作する場合）、`/drive/AgentDrive`、会話ごとに分離された `/drive/ChatDrive` に加え、[Agent Library](../agent-library/) に基づく読み取り専用の `/drive/Brain`、`/drive/Skills`、`/drive/AGENTS.md`、`/drive/DESIGN.md` を公開します。バックグラウンドの VFS 書き戻しが `412` または `422` の競合で拒否された場合、下書きバイトはそのスコープの `/drive-recovery` に保全されます。起動時プローブで FUSE をマウントできない Worker では、代わりに `ankole-files` CLI でドライブファイルを転送します（[ファイル管理](../file-management/) を参照）。`~/AGENTS.md`、`~/DESIGN.md`、および `$CODEX_HOME/AGENTS.md` も各 Turn で有効な規約を反映し、Background Agent Job は許可された Skill パッケージを `.ankole/turn-skills/<signal-id>/` に配置します（初回の許可リストは権限剥奪で縮小することはあっても、後から拡大はしません）。`sessions/` は PostgreSQL が `10000` から割り当てる固定数値 ID ごとの会話ワークスペース、`jobs/` はプロジェクト独自の指示ファイルを含む作業領域です。

Agent Home の内容は、インスタンスの削除やコンテナイメージの更新後も保持されます。環境を再構築した際に削除されるのは `/var/cache/ankole` のみです。ただし、Docker のローカル volume は実行ホストに依存するほか、Cloudflare 環境で強制停止が発生した場合は最後の R2 バックアップ以降の書き込みが失われることがあります。こうした制約については [Worker](../worker-management/) を参照してください。

生の Codex スレッドファイルは `/workspace/.codex` に永続化される一方、`AgentCodexRuntime` はアクティブな Codex ランタイムエントリ、`CODEX_HOME`、および `/var/cache/ankole/codex` 配下の再構築可能な SQLite キャッシュを実行ビュー（会話 Identity を含むため、`ChatDrive` や開示範囲がビューごとに分離される）ごとに分割管理します。インスタンスの置換でキャッシュが初期化されても `/workspace/.codex` から処理を再開でき、Background Job で Skill を読み込む際は `skill_view` を使用します。

## 進捗と容量

メインループのストリーミング配信とツール実行状況の表示は Driver が担当し、Worker は環境ツールの結果や Codex の進捗を RuntimeFabric 経由で送信します。この進捗通知はベストエフォートであり、障害発生時の復旧では PostgreSQL に保存された完了記録と実行結果が正本として使われます。

また、Worker は heartbeat を通じてアクティブな workspace、実行中の Codex turn、空き slot 数を報告します。control plane は provider YAML の `idleReleaseAfter` に従ってアイドル状態のインスタンスを回収しますが、`never` が指定されている場合はそのまま稼働し続けます。一時的な切断後に再接続した場合も、プロセスの incarnation と進行中の作業はそのまま維持されます。

writer と操作のフェンスについては [Sessions](../sessions/)、Responses については [AIGateway](../ai-gateway/)、Skills については [Agent Library](../agent-library/)、provider の状態管理については [Workers](../worker-management/) を参照してください。
