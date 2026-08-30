---
title: コード実行
description: Ankole の Agent が、通常の会話または永続的な Background Agent Job としてコードを実行する方法。
section: Developer guide
order: 122
---

Agent は、通常の会話の中でコマンドを実行し、ファイルを編集できます。また、永続的な作業を Background Agent Job に委ねることもできます。これらは別々の runtime パスです。会話は Agent Computer Worker のフォアグラウンド tool を使い、各 Background Agent Job は CodexRunner を使います。メッセージ内のコード量が、どちらを選ぶかを決めるわけではありません。

決定的な性質を先に述べます。すべてのコマンドは隔離されて実行されます。shell コマンドは bubblewrap の下で、`SYS_ADMIN`、非制限の seccomp、マスクされていない `/proc` 付きで実行されます——これは worker のハード要件であり、オペレーターの選択ではありません。Agent は `/agents` 配下の Agent 単位のファイルシステムの中で作業し、shell を経由して sandbox から逃げることは決してありません。

## bubblewrap の下の shell コマンド

Agent は command tool を通じて shell コマンドを実行します。それは `app/agent_computer/src/tools/computer/command-tool.ts` と、`bubblewrap.ts` の bubblewrap 隔離によって支えられています。model が要求するすべてのコマンドは、`SYS_ADMIN`、非制限の seccomp ポリシー、マスクされていない `/proc` 付きで bubblewrap の下で実行されます。マスクされていない `/proc` と `SYS_ADMIN` ケーパビリティにより、[browser](../browser-automation/) daemon と Jupyter kernel が同じ隔離の中で実行できます。このプロファイルは [Quick start](../quickstart/#deployment) に文書化された Worker イメージ要件であり、Agent ごとに調整するものではありません。

実際にはこういう意味です。shell コマンドは Agent の workspace の下のファイルを読み書きでき、インストール済み tool を実行でき、worker イメージが提供するサブプロセスを起動できます。別の Agent の workspace には到達できず、control-plane の状態にも到達できません。sandbox が境界です。

## ファイル読み取りと apply_patch

shell に加えて、computer tools は Agent に 2 つのファイルプリミティブを提供します。

- **ファイルの読み取り**——`read-file-tool.ts`。`cat` に shell out するのではなく、ファイルの内容を直接検査します。
- **ファイルの編集**——`apply-patch-tool.ts`。固定された Codex リリースと同じ文法を使う、freeform の `apply_patch` tool です。

Main Agent は生の patch を `custom_tool_call` として AIGateway を通じて送ります。Worker はそれを `/usr/local/bin/apply_patch` を通じてネイティブの Codex バイナリに渡します。Background Agent Job は AIGateway の model card から同じ freeform tool を受け取り、同じバイナリを使います。Ankole は別の patch パーサーを保持しません。

この共有パスにより、通常の会話と Background Agent Job は 1 つの編集プロトコルに留まります。一致しない patch はネイティブ tool で失敗し、その失敗が model に返されます。素早い検索には shell で十分です。ファイル編集には `apply_patch` を使ってください。

## /agents ファイルシステム

Agent が読み書きするすべては `/agents` の下に置かれ、Agent キーごとにレイアウトされます。Agent はコンテナパスを直接見ます——worker は model のためにパスを変換しません:

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

`SOUL.md`、`MISSION.md`、`DESIGN.md` は [Agent Library](../agent-library/) の永続ドキュメントです。最初の 2 つは責任と振る舞いを定義します。`DESIGN.md` はビジュアル作業のためのデザインシステムです。`installed-skills/` は Agent Skill を保持します。`sessions/` は、10000 から始まる PostgreSQL 所有の安定した数値 ID を持つ会話 workspace を保持し、`jobs/` は別の Background Agent Job workspace を保持します。

Background Agent Job は Ankole `skill_view` を通して Skill を読み込み、Skill root を Job ワークスペースへコピーしません。

## 反復的な Python のための Jupyter live kernel

作業が反復的な Python——実行をまたいで保持する変数、cell ごとに検査したい DataFrame、ステートフルな REPL——の場合、shell は間違った tool です。`jupyter-live-kernel` Skill が正しい tool です。これは builtin Skill（`default_enabled: true`）で、[background job](../background-jobs/) として実行され、hamelnb を囲む Ankole の Unix-socket アダプター上に構築されています。kernel は実行をまたいで生存し続けるため、呼び出しのたびにデータを再ロードする代わりに、1 つのステップで変数を定義し、次のステップでそれを読むことができます。

Skill 自身のガイダンスが経験則です。短くステートレスな Python スクリプトには、ワンショットの shell 実行を優先します。Jupyter notebook またはステートフルな Python REPL が欲しい場合は、この Skill を優先します。データサイエンス、DataFrame の検査、notebook の編集、ステートフルな API 探索が、この Skill の得意分野です。システム Python、JupyterLab、ipykernel、hamelnb ヘルパーは既に worker イメージに入っているため、新しい Agent は何もインストールせずにこの Skill を使えます。

## Background Agent Job の CodexRunner

CodexRunner はすべての Background Agent Job の実行エンジンです。Job はトピックの調査、ドキュメントの作成、リポジトリの変更、その他の長時間の作業ができます。CodexRunner を選ぶのは、そのライフサイクルであり、主題ではありません。runner は `app-server-client.ts` を通じて Codex app-server と通信し、別の Job workspace と runtime 設定を準備します。

Console は対応する model profile を **Background Agent Jobs** と表示します。その保存キーと API 名は、当面 `coding` のままです。これはレガシー名であり、コード量の多い会話を検出する規則ではありません。

## これらのパスの選択方法

オペレーターの操作面は狭いです。

- **Computer tools**（`command`、`read_file`、`apply_patch`）はすべての Worker に同梱されます。通常の会話の Turn で利用できます。
- **Jupyter live kernel** は `default_enabled` の Skill なので、[browser](../browser-automation/) Skill を制御するのと同じ方法で [Agent Library](../agent-library/) を通じて制御します。反復的な Python を実行すべきでない Agent では狭めてください。
- **CodexRunner** はすべての Background Agent Job を実行します。すべての model 呼び出しは AIGateway を通ります。Job が別の provider または model を必要とする場合は、Background Agent Jobs profile を設定します。未設定の場合、control plane は Agent の `heavy` profile を使います。

## 次のステップ

- これらの tool を実行し、`/agents` ファイルシステムを所有する Worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
- Jupyter Skill の背後にある Skill と有効化モデルについては、[Agent Library](../agent-library/) を読んでください。
- 内部キーが `coding` のままの Background Agent Jobs profile については、[Background Agent Jobs](../background-jobs/#モデル-provider-を選択する) を読んでください。
- Worker イメージが要求する隔離については、[Quick start](../quickstart/#deployment) を読んでください。
