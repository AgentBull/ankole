---
title: コード実行
description: Ankole の Agent が、通常の会話または永続的な Background Agent Job としてコードを実行する方法。
section: Developer guide
order: 122
---

Agent は、通常の会話の中でコマンドを実行し、ファイルを編集できます。また、永続的な作業を Background Agent Job に委ねることもできます。これらは別々の runtime パスです。会話は Agent Computer Worker のフォアグラウンド tool を使い、各 Background Agent Job は CodexRunner を使います。メッセージ内のコード量が、どちらを選ぶかを決めるわけではありません。

決定的な性質を先に述べます。すべてのコマンドは Agent 自身のコンピュータで実行されます。各 Agent は自分専用の Worker コンテナを持ち、コンテナが唯一の隔離境界です。コマンドは内側の sandbox なしで Worker のユーザーとして実行され、Agent は `/workspace` 配下の自分の Agent Home で作業します。Agent は自分のコンピュータを変更できますが、Worker、キャッシュディスク、credential を別の Agent と共有することはありません。

## shell コマンド

Agent は command tool を通じて shell コマンドを実行します。それは `app/agent_computer/src/tools/computer/command-tool.ts` によって支えられています。各コマンドは Worker のユーザーとして独自のプロセスグループで実行され、Worker の credential を含まない新しい環境を使います。キャンセルまたはタイムアウトはグループ全体を終了させます。フォアグラウンドの既定の予算は 180 秒です。作業ディレクトリは Agent Home の中になければなりません。[browser](../browser-automation/) daemon、Codex app-server、Automation スクリプトも Worker のユーザーとして実行され、Worker に追加のカーネル権限は必要ありません。

コマンドは sudo なしの uid 1000 で実行します。Home への書き込み、ユーザー用パッケージの導入、子プロセスの起動は可能ですが、システムパッケージは導入できません。同じ Agent の Session と Job はファイルを共有します。Agent 間はインスタンスで隔離し、Worker はデータベース接続やオブジェクトストア認証情報を持ちません。

## ファイル読み取りと apply_patch

shell に加えて、computer tools は Agent に 2 つのファイルプリミティブを提供します。

- **ファイルの読み取り**——`read-file-tool.ts`。`cat` に shell out するのではなく、ファイルの内容を直接検査します。
- **ファイルの編集**——`apply-patch-tool.ts`。固定された Codex リリースと同じ文法を使う、freeform の `apply_patch` tool です。

Main Agent は生の patch を `custom_tool_call` として AIGateway を通じて送ります。Worker はそれを `/usr/local/bin/apply_patch` を通じてネイティブの Codex バイナリに渡します。Background Agent Job は AIGateway の model card から同じ freeform tool を受け取り、同じバイナリを使います。

この共有パスにより、通常の会話と Background Agent Job は 1 つの編集プロトコルに留まります。一致しない patch はネイティブ tool で失敗し、その失敗が model に返されます。素早い検索には shell で十分です。ファイル編集には `apply_patch` を使ってください。

## /workspace ファイルシステム

Agent Home は `/workspace` の永続ストレージです。`/agents/<agent_uid>` は `/workspace` へのシンボリックリンクです。パス検証はシンボリックリンクを解決してから Home の境界を確認します。構成は次のとおりです。

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

`SOUL.md`、`MISSION.md`、`DESIGN.md` は [Agent Library](../agent-library/) の永続ドキュメントです。最初の 2 つは責任と振る舞いを定義します。`DESIGN.md` はビジュアル作業のためのデザインシステムです。`installed-skills/` は Agent Skill を保持します。`sessions/` は、10000 から始まる PostgreSQL 所有の安定した数値 ID を持つ会話 workspace を保持し、`jobs/` は別の Background Agent Job workspace を保持します。

Home はインスタンス削除やイメージ変更後も残ります。再構築は `/var/cache/ankole` だけを削除します。Docker のローカル volume はホストに依存し、Cloudflare の強制停止は最終 R2 バックアップ後の書き込みを失う場合があります。制限は [Worker](../worker-management/) を参照してください。

control plane のドライブは添付ファイル、公開ファイル、Skill、Automation スクリプトを別途保存します。`ankole-files` で読み書きします。Job workspace と Codex スレッドは永続 Home に残ります。Turn の前に `installed-skills/` をドライブと同期します。

Background Agent Job は `skill_view` を通してオンデマンドで Skill を読み込みます。

## 反復的な Python のための Jupyter live kernel

作業が反復的な Python——実行をまたいで保持する変数、cell ごとに検査したい DataFrame、ステートフルな REPL——の場合、shell は間違った tool です。`jupyter-live-kernel` Skill が正しい tool です。これは builtin Skill（`default_enabled: true`）で、[background job](../background-jobs/) として実行され、hamelnb を囲む Ankole の Unix-socket アダプター上に構築されています。kernel は実行をまたいで生存し続けるため、呼び出しのたびにデータを再ロードする代わりに、1 つのステップで変数を定義し、次のステップでそれを読むことができます。

Skill 自身のガイダンスが経験則です。短くステートレスな Python スクリプトには、ワンショットの shell 実行を優先します。Jupyter notebook またはステートフルな Python REPL が欲しい場合は、この Skill を優先します。データサイエンス、DataFrame の検査、notebook の編集、ステートフルな API 探索が、この Skill の得意分野です。システム Python、JupyterLab、ipykernel、hamelnb ヘルパーは既に worker イメージに入っているため、新しい Agent は何もインストールせずにこの Skill を使えます。

## Background Agent Job の CodexRunner

CodexRunner はすべての Background Agent Job の実行エンジンです。Job はトピックの調査、ドキュメントの作成、リポジトリの変更、その他の長時間の作業ができます。CodexRunner を選ぶのは、そのライフサイクルであり、主題ではありません。runner は `app-server-client.ts` を通じて Codex app-server と通信し、別の Job workspace と runtime 設定を準備します。

Console は対応する model profile を **Background Agent Jobs** と表示します。その保存キーと API 名は `coding` です。

## これらのパスの選択方法

オペレーターの操作面は狭いです。

- **Computer tools**（`command`、`read_file`、`apply_patch`）はすべての Worker に同梱されます。通常の会話の Turn で利用できます。
- **Jupyter live kernel** は `default_enabled` の Skill なので、[browser](../browser-automation/) Skill を制御するのと同じ方法で [Agent Library](../agent-library/) を通じて制御します。反復的な Python を実行すべきでない Agent では狭めてください。
- **CodexRunner** はすべての Background Agent Job を実行します。すべての model 呼び出しは AIGateway を通ります。Job が別の provider または model を必要とする場合は、Background Agent Jobs profile を設定します。未設定の場合、control plane は Agent の `heavy` profile を使います。

## 次のステップ

- これらの tool を実行し、`/workspace` ファイルシステムを所有する Worker については、[Agent Computer Worker](../agent-computer-worker/) を読んでください。
- Jupyter Skill の背後にある Skill と有効化モデルについては、[Agent Library](../agent-library/) を読んでください。
- 内部キーが `coding` のままの Background Agent Jobs profile については、[Background Agent Jobs](../background-jobs/#モデル-provider-を選択する) を読んでください。
- Worker の信頼境界とその強化方法については、[Security hardening](../security-hardening/) を読んでください。
