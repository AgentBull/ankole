---
title: Agent Computer Worker
description: 環境ツール、Codex、永続 Home、control plane 置換後の復旧。
section: Developer guide
order: 108
---

Agent Computer Worker は、個々の Agent に割り当てられる専用コンピュータ環境です。Agent の作成時点では、選択された provider と `absent` 状態の Worker レコードだけが保存され、環境ツールや Codex が初めて必要になったタイミングで control plane が実体を起動します。通常の質疑応答や control plane 側で完結するツールの実行には、Worker は必要ありません。

## 実行と所有権

Bun ベースの Worker は、シェルコマンド、ファイル操作やブラウザ操作のツール、Skills、MCP 呼び出し、automation スクリプト、および Codex Job を実行します。一方、メインの Agent ループ、入力完了やツール実行結果のコミット、最終返信の確定は control plane の `Ankole.Sessions` が担当し、永続 Response チェーンと hosted ツールは AIGateway が管理します。

起動時、control plane は Worker に対して `WORKER_ID`、RuntimeFabric の URL、世代（generation）ごとの認証情報、およびストレージ設定を渡します。Worker は担当する 1 つの Agent の処理だけを行い、子プロセスの環境変数からは認証情報を除外し、データベースにも直接接続しません。コンテナ自体が Agent ごとの分離境界となり、内部のコマンドは `sudo` 権限を持たない `uid 1000` として動作します。

## Worker pool とライブ接続

Agent に保存された Worker provider の設定によって、使用する pool、プラットフォーム、インスタンス構成、ストレージが決まります。複数の Agent で同じ pool を共有できますが、プラットフォーム上では Agent ごとに専用のコンピュータが作成されます。アイドル状態が続くと、Agent Home のデータを保持したままインスタンスが削除または休止されます。設定やライフサイクルの詳細については、[Worker pool](../worker-management/) を参照してください。

起動した Worker は `/runtime-fabric/worker/websocket` に対して認証済み WebSocket 接続を 1 本確立し、専用の Phoenix Channel に参加します。環境ツールの呼び出しや実行結果、Codex の制御メッセージ、進捗通知はすべて RuntimeFabric の protobuf envelope で送受信されます。その際、control plane は generation と incarnation を検証し、すでに置き換えられた古い Worker からの接続を拒否します。なお、ファイル本体は 1 回限りの HTTP 中継 URL を経由して転送され、復旧に必要な永続データは PostgreSQL に記録されます。

## 操作の識別と復旧

環境作業の `RunRef` には Agent、Session、およびトリガーとなった入力が指定され、個々のツール呼び出しは Response ID と call ID で一意に識別されます。control plane 側で新しい Driver が立ち上がった場合は、既存の workspace の状態を確認し、実行中の呼び出しを引き継ぐか完了済みの結果を取得します。control plane との接続が一時的に切れても、Worker 上のコマンド実行はそのまま継続します。もし Worker プロセス自体が失われた場合は、再実行しても安全な呼び出しだけがリトライされ、結果が確定しない呼び出しには `interrupted` が返されます。

一方、Codex では Job ID と attempt を含む `JobTurnRef` を使用します。`adopt` 操作を行うと、実行中の turn、スレッド、workspace がそのまま引き継がれます。Job のオーナーは attempt のフェンスを用いて終端状態の書き込みを検証し、適用済み入力 ID の完了処理を同一トランザクション内でコミットします。なお、Codex は Worker 内部に独自のモデルループを持っています。

開いている環境 workspace と実行中の Codex turn は、それぞれ Worker の実行枠（slot）を 1 つずつ消費します。メイン会話や Workflow におけるモデル呼び出しは Worker slot を消費しません。

## ファイルシステム契約

Agent Home は `/workspace` にマウントされる永続ストレージであり、`/agents/<agent_uid>` は `/workspace` を指すシンボリックリンクになっています。パス検証では、先にシンボリックリンクを解決したうえでアクセス先が Agent Home の境界内に収まっているかを確認します。ディレクトリ構成は次のとおりです。

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

モデルにはコンテナ内の絶対パスがそのまま見えるため、Worker 側でのパス変換は行われません。また、コマンドの作業ディレクトリは常に Agent Home 配下である必要があります。直下の 4 つのドキュメントのうち、`SOUL.md` と `MISSION.md` は Agent の振る舞いと責務を定義し、`DESIGN.md` は視覚的な成果物のデザインシステムを、`ConfidentialityPolicy.md` は Brain へ書き込む際の公開範囲の判断基準を定めます。これら 4 文書は [Agent Library](../agent-library/) が管理します。また、`installed-skills/`、`sessions/`、`jobs/` にはそれぞれ Skill、会話ごとのワークスペース、Background Agent Job 用のワークスペースが配置されます。各 Session には、PostgreSQL によって `10000` から始まる不変の数値ワークスペース ID が割り当てられます。

Agent Home の内容は、インスタンスの削除やコンテナイメージの更新後も保持されます。環境を再構築した際に削除されるのは `/var/cache/ankole` のみです。ただし、Docker のローカル volume は実行ホストに依存するほか、Cloudflare 環境で強制停止が発生した場合は最後の R2 バックアップ以降の書き込みが失われることがあります。こうした制約については [Worker](../worker-management/) を参照してください。

添付ファイル、公開ファイル、Skill、Automation スクリプトは control plane 側のドライブに別途保存されており、Worker からは `ankole-files` を使って読み書きします。一方、Job workspace と Codex スレッドは永続 Home 側に残ります。Turn が始まる前には、ドライブ上の内容と `installed-skills/` が同期されます。

Codex Home は `/workspace/.codex` に配置されます。スレッドファイルはインスタンスの置換後も保持されるため、`/var/cache/ankole/codex` にある再構築可能な SQLite キャッシュが初期化されても処理を再開できます。Background Job で Skill を読み込む際は `skill_view` を使用します。

## 進捗と容量

メインループのストリーミング配信とツール実行状況の表示は Driver が担当し、Worker は環境ツールの結果や Codex の進捗を RuntimeFabric 経由で送信します。この進捗通知はベストエフォートであり、障害発生時の復旧では PostgreSQL に保存された完了記録と実行結果が正本として使われます。

また、Worker は heartbeat を通じてアクティブな workspace、実行中の Codex turn、空き slot 数を報告します。control plane は provider YAML の `idleReleaseAfter` に従ってアイドル状態のインスタンスを回収しますが、`never` が指定されている場合はそのまま稼働し続けます。一時的な切断後に再接続した場合も、プロセスの incarnation と進行中の作業はそのまま維持されます。

writer と操作のフェンスについては [Sessions](../sessions/)、Responses については [AIGateway](../ai-gateway/)、Skills については [Agent Library](../agent-library/)、provider の状態管理については [Workers](../worker-management/) を参照してください。
