---
title: Agent Computer Worker
description: Bun と TypeScript の Worker が、コントロールプレーンが各ターンをフェンス管理する一方で、モデルループ、ツール、ファイル、ターミナル状態、ストリーミング出力をどのように実行するか。
section: Developer guide
order: 108
---

Agent Computer Worker は Agent の実行ノードです。会話が起床すると、Actor Runtime はフェンス管理されたターンを Worker に渡します。Worker はモデルループ、ツール、ファイル、ターミナル作業を実行し、結果をコントロールプレーンに返します。このページは `app/agent_computer` が実装する境界を説明します。

決定的な性質を先に述べます: worker が所有するのは、ライブ実行と再構築可能な worker ローカル状態だけであり、それ以上ではありません。永続状態（トランスクリプト、フェンス、最終コミット）はコントロールプレーンに残ります。worker は交換可能であり、遅延または拠点外の worker 書き込みはフェンスに失敗して破棄されます。

## 所有権の境界

この分割は worker 自身のコントラクトに明示されています。Agent Computer Worker はライブ実行と再構築可能な worker ローカル状態を所有します。Elixir コントロールプレーンは PostgreSQL の状態、actor と配信のフェンス、最終コミット権限、provider outbox、実行時認証情報、復旧事実を所有します。worker は永続的なコントロールプレーン状態を勝手に作ってはなりません。

ここから実際に除外されるもの: `DATABASE_URL`、`ANKOLE_AGENT_UID`、`ANKOLE_SESSION_ID`、`ANKOLE_ACTOR_EPOCH` は worker の入力ではありません。actor アイデンティティは環境ではなく `turn_start` で届きます。worker は `WORKER_ID`、`ANKOLE_RUNTIME_FABRIC_ENDPOINT`、別の secret である `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` で RuntimeFabric に認証します。`ANKOLE_AGENTS_ROOT` は共有ワークスペースの場所を示します。worker はデータベース接続を持たず、自分が誰のために動いているかを決定しません。

## ターンフェンス

worker が実行するすべてのターンは、3 つのフィールド（`activation_uid`、`actor_epoch`、`actor_event_id`）を持つ `ActorTurnRef` によって固定されます。1 回の worker 実行は正確に 1 つの `actor_event_id` を処理します。worker はin-memoryのアクティブターン状態を `${activation_uid}:${actor_event_id}` をキーとして保持し、コントロールプレーンに返すすべてのエンベロープがその ref を運びます。

これは [Actor Runtime](../actor-runtime/) トリプルフェンスの worker 側です。コントロールプレーンは受信した各 worker 書き込みを、アクティベーション、エポック、配信行と照合してチェックします。worker の ref がもはや一致しなければ（アクティベーションが置き換えられた、リースが期限切れになった、イベントがより高いエポックで再試行された）、その書き込みは stale として拒否されます。worker はもはや所有していないターンにコミットすることはできません。

## モデルループ

Agent ループは、AIGateway のステートフル転送に対する worker 駆動の Responses ループであり、意図的に小さく保たれています。4 つのステップです:

1. ターンスコープの OpenAI Responses adapter を通じてモデルを呼び出す。
2. 応答に関数呼び出し項目が含まれていれば、ローカルで実行する。
3. 関数呼び出しの出力を AIGateway 経由で記録する。
4. 記録されたジャーナルアンカーから、関数呼び出し項目が返ってこなくなるまで続ける。

worker はループの終了とローカルの反復予算を所有します。履歴の展開、圧縮、継続アンカー、永続的な応答状態は所有**しません**。これらは AIGateway に残ります。ループが終わったときの結果は 2 つのうちのいずれかです: `loop_finished`（モデルがさらなるツール呼び出しなしで返った）または `iteration_exhausted`（worker が反復上限に達し、モデルがこれ以上のツール呼び出しではなく最終回答を合成するよう促された）。worker はターン全体の結果をコントロールプレーンに報告し、コントロールプレーンがそれを記録します。

## ツール: worker 内で実行されるもの

ツールは、ループ中にモデルが駆動できるローカルアクションです。worker はそれらをカテゴリとして提供し、それぞれが実際の worker コードで実装されています:

- **Computer** — シェルコマンド（bubblewrap の制約下）、ファイル読み取りとパッチ、apply-patch、実ブラウザのデスクトップを駆動する v4a computer-use ツール。ターミナル状態とファイル編集はここにあります。
- **Web** — Web 検索と Web 取得。worker 経由でルーティングされます。
- **Brain** — 長期記憶に遡る recall と知識ツール。
- **Memory、schedule、todo、clarify** — Agent が計画、延期、質問に使う、より小さな構造化ツール。
- **Codex** — Background Agent Job に委任する作業のための CodexRunner Job ツール。
- **Library と mcporter** — 有効な Skill と呼び出しスコープの MCP 依存関係設定へのアクセス。
- **Background Agent Job** — 永続的な Job を作成または継続するハンドオフツール。

worker が生成するすべてのツール結果は、直接コミットされるのではなく、関数呼び出し出力として AIGateway を通じて記録されます。モデルは結果を見ますが、何が永続的かを決めるのはコントロールプレーンです。

## ファイルシステム契約

永続的な共有書き込み可能ランタイムマウントは `/agents` で、actor キーごとに次のように配置されます:

```text
/agents/<agent-key>/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

モデルはコンテナ内の絶対パスを見ます。Worker はパスを変換しません。`SOUL.md` と `MISSION.md` は Agent の挙動と責任を定義します。`DESIGN.md` は視覚的な作業のためのデザインシステムです。[Agent Library](../agent-library/) がこの 3 つを管理します。`installed-skills/`、`sessions/`、`jobs/` は Skill、会話ワークスペース、Background Agent Job ワークスペースを保持します。PostgreSQL は各 Session に 10000 から始まる安定した数値ワークスペース ID を割り当てます。

## ストリーミングと進捗

ターン実行中、worker はベストエフォートで重複しないエンベロープとして進捗を公開します。一定間隔ごとにチェックポイントがあり、言う価値があるときにはアクティビティサマリーが付きます。進捗は意図的に永続化メカニズムではありません。停滞した進捗送信がタイマーを積み上げたり、それが記述しているループをブロックしたりしてはいけません。モデルとツールが生成するストリーミング出力は同じ RuntimeFabric レーンを通って戻ります。何が永続的になるかは、worker がストリーミングする時点ではなく、コミット時にコントロールプレーンが決定します。

worker は小さなアドミッションヒント（in-memory状態から見た残りターン容量）も公開します。これによりコントロールプレーンは満杯のプロセスに作業を送るのを避けられます。スケジューリングはコントロールプレーンに残ります。ヒントはあくまでヒントです。

## Agent Computer Worker がそうでないもの

スタンドアロンのローカル CLI ではありません。Linux worker イメージの中で実行され、ネイティブカーネルバインディング、bubblewrap、Chromium、Python/Jupyter とドキュメントツール、ZeroMQ、共有 agent ファイルシステムを提供します。永続状態を勝手に作る場所でもありません。worker の仕事はフェンス管理されたターンを実行して報告することであり、永続的な決定はすべてコントロールプレーンのものです。そして、2 つ目のスケジューラーでもありません。起床、リース、再試行を所有するのは Actor Runtime です。境界は明確です: ターンのアイデンティティと真実はコントロールプレーン、ターンの実行は worker が所有します。

## 次のステップ

- worker を 1 つのアクティベーションに固定するフェンスについては、[Actor Runtime](../actor-runtime/) ページを読んでください。
- ループが呼び出すステートフルな Responses 転送については、[AIGateway API](../ai-gateway/) を読んでください。
- worker が `/agents` から読み取る Skill とドキュメントについては、[Agent Library](../agent-library/) ページを読んでください。
