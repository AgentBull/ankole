---
title: Agent Computer Worker
description: 環境ツール、Codex、永続 Home、control plane 置換後の復旧。
section: Developer guide
order: 108
---

Agent Computer Worker は 1 つの Agent のコンピュータです。Agent 作成時は provider の選択と absent Worker 行を保存します。環境ツールまたは Codex が初めて必要になった時点で control plane が起動します。質問と control plane のツールには Worker は不要です。

## 実行と所有権

Bun Worker はコマンド、ファイルとブラウザのツール、Skills、MCP 呼び出し、automation script、Codex Job を実行します。control plane の `Ankole.Conversations` は主 Agent loop、入力完了とツール結果のコミット、最終返信を所有します。AIGateway は永続 Response チェーンと hosted ツールを所有します。

control plane は `WORKER_ID`、RuntimeFabric URL、generation の認証情報、ストレージ設定を渡します。Worker は自身の Agent だけを処理し、子プロセス環境から認証情報を除き、データベースには接続しません。コンテナが Agent の分離境界です。コマンドは sudo なしの uid 1000 で動作します。

## Worker pool とライブ接続

Agent に保存した Worker provider が pool、プラットフォーム、インスタンス設定、ストレージを選びます。複数の Agent が同じ pool を使えますが、プラットフォームは Agent ごとに専用コンピュータを作成します。アイドル時はインスタンスを削除または休止して Home を保持します。設定とライフサイクルは [Worker pool](../worker-management/) を参照してください。

Worker は `/runtime-fabric/worker/websocket` に認証済み WebSocket を 1 本開き、専用 Phoenix Channel に参加します。RuntimeFabric の protobuf envelope は環境呼び出し、結果、Codex 制御、進捗を運びます。generation と incarnation の確認で置換済み Worker を拒否します。ファイルのバイト列は 1 回限りの HTTP 中継 URL を通り、永続的な復旧事実は PostgreSQL が保持します。

## 操作の識別と復旧

環境作業の `RunRef` は Agent、Session、trigger 入力を指定します。各呼び出しは Response ID と call ID で識別します。新 Driver は既存 workspace を調べ、進行中の呼び出しを引き継ぐか結果を取得します。control plane の切断後もコマンドは続きます。Worker プロセスを失った場合、安全な呼び出しだけを再試行し、それ以外の不明な呼び出しは `interrupted` を返します。

Codex は Job ID と attempt を含む `JobTurnRef` を使います。`adopt` は同じ実行中の turn、thread、workspace を保持します。Job owner は attempt のフェンスで終端書き込みを受け入れ、適用済み入力 ID を同じトランザクションで完了します。Codex は独自のモデル loop を保持します。

開いている環境 workspace と実行中の Codex turn はそれぞれ 1 slot を使います。主会話と Workflow のモデル呼び出しは Worker slot を使いません。

## ファイルシステム契約

Agent Home は `/workspace` の永続ストレージです。旧パス `/agents/<agent_uid>` は Home へのリンクです。パス検証はシンボリックリンクを解決してから Home の境界を確認します。構成は次のとおりです。

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

モデルはコンテナ内の絶対パスを見ます。Worker はパスを変換せず、コマンドの作業ディレクトリは Agent Home の中になければなりません。`SOUL.md` と `MISSION.md` は Agent の挙動と責任を定義します。`DESIGN.md` は視覚的な作業のためのデザインシステムです。`ConfidentialityPolicy.md` は Brain 書き込み時の公開範囲の選択を指示します。[Agent Library](../agent-library/) がこの 4 文書を管理します。`installed-skills/`、`sessions/`、`jobs/` は Skill、会話ワークスペース、Background Agent Job ワークスペースを保持します。PostgreSQL は各 Session に 10000 から始まる安定した数値ワークスペース ID を割り当てます。

Home はインスタンス削除やイメージ変更後も残ります。再構築は `/var/cache/ankole` だけを削除します。Docker のローカル volume はホストに依存し、Cloudflare の強制停止は最終 R2 バックアップ後の書き込みを失う場合があります。制限は [Worker](../worker-management/) を参照してください。

control plane のドライブは添付ファイル、公開ファイル、Skill、Automation スクリプトを別途保存します。`ankole-files` で読み書きします。Job workspace と Codex スレッドは永続 Home に残ります。Turn の前に `installed-skills/` をドライブと同期します。

Codex Home は `/workspace/.codex` です。スレッドファイルは置換後も残り、`/var/cache/ankole/codex` の SQLite が失われても再開できます。Background Job は `skill_view` で Skill を読み、Skill ルートを workspace にコピーしません。

## 進捗と容量

Driver は主 loop のストリーミングとツール表示を所有します。Worker は RuntimeFabric で環境結果と Codex の進捗を送ります。進捗は best effort であり、復旧は PostgreSQL の完了事実と保存結果を使います。

heartbeat は active workspace、Codex turn、空き slot を報告します。control plane は provider YAML の `idleReleaseAfter` で idle instance を回収します。`never` は実行を続けます。再接続はプロセス incarnation と進行中の作業を保持します。

writer と操作のフェンスは [Actor Runtime](../actor-runtime/)、Responses は [AIGateway](../ai-gateway/)、Skills は [Agent Library](../agent-library/)、provider 状態は [Workers](../worker-management/) を参照してください。
