---
title: コード実行
description: Ankole の Agent が通常の会話ターンや永続的な Background Agent Job の中でどのようにコードを実行・編集するかを説明します。
section: Developer guide
order: 122
---

Agent は、通常の会話の中でシェルコマンドを実行したりファイルを編集したりできるほか、時間のかかる作業を Background Agent Job へ委任することもできます。この 2 つは実行パスが異なります。通常の会話では Agent Computer Worker のフォアグラウンドツールを使い、Background Agent Job では `CodexRunner` を使います。メッセージに含まれるコードの分量で決まるわけではなく、作業のライフサイクルに応じて使い分けられます。

まず最も重要な前提として、**Agent が実行するすべてのコマンドは、その Agent 専用のコンピュータ環境上で動作します。** 各 Agent は独立した Worker コンテナを持ち、コンテナ自体が分離境界となっています。コマンドは追加の内側サンドボックスなしで Worker の実行ユーザーとして動き、`/workspace` 配下の Agent Home で作業を行います。Agent は自身のコンピュータ環境を自由に変更できますが、別の Agent と Worker・キャッシュディスク・認証情報を共有することは一切ありません。なお、Pod Applet のバックエンド関数や、AIGateway・Workflow における Programmatic Tool Calling（PTC）スクリプトは、Agent Computer Worker 上ではなくステートレスな `ankole-function-runtime` の isolate 内で実行されます。

## shell コマンド

Agent は `app/agent_computer/src/tools/computer/command-tool.ts` で実装された `command` ツールを通じてシェルコマンドを実行します。各コマンドは Worker の実行ユーザー権限で独立したプロセスグループとして起動され、Worker 自体の認証情報を除外したクリーンな環境変数セットが渡されます。キャンセルやタイムアウトが発生した際は、プロセスグループ全体がまとめて終了します。フォアグラウンド実行の既定タイムアウトは 180 秒であり、作業ディレクトリは必ず Agent Home 配下でなければなりません。なお、[browser](../browser-automation/) デーモン、Codex app-server、および Automation スクリプトも同じユーザー権限で動作するため、Worker に特別なカーネル特権は不要です。

実行ユーザーは `sudo` 権限を持たない `uid 1000` です。Agent Home へのファイル書き込み、ユーザー領域へのパッケージ追加、子プロセスの起動は自由に行えますが、OS レベルのシステムパッケージを追加することはできません。同一 Agent 内の Session と Job は同じファイル領域を共有し、異なる Agent 間はコンテナインスタンス単位で完全に分離されます。また、Worker 自体はデータベース接続やオブジェクトストアの認証情報を保持しません。

## ファイル読み取りと apply_patch

シェル実行に加えて、computer tools にはファイル操作専用のプリミティブが 2 つ用意されています。

- **ファイルの読み取り（`read-file-tool.ts`）**: いちいちシェルから `cat` を呼ばずに、ファイルの内容を直接読み取ります。
- **ファイルの編集（`apply-patch-tool.ts`）**: 固定バージョンの Codex リリースと同一の文法を採用した、フリーフォーム形式の `apply_patch` ツールです。

メイン Agent は AIGateway を通じて生のパッチテキストを `custom_tool_call` として送信し、Worker がそれを `/usr/local/bin/apply_patch` にあるネイティブの Codex バイナリへ渡して適用します。Background Agent Job でも AIGateway のモデルカードから同じフリーフォームツール定義を受け取り、同じネイティブバイナリを使用します。

この共通化により、通常の会話と Background Agent Job の両方でファイル編集プロトコルが 1 つに統一されています。対象ファイルの内容と一致しないパッチはネイティブツール側で安全に失敗し、エラー内容がそのままモデルへ返されます。手早いファイル検索にはシェルコマンドが便利ですが、ファイルの書き換えには `apply_patch` を使用します。

## /workspace ファイルシステム

Agent Home は `/workspace` にマウントされる永続ストレージであり、`/agents/<agent_uid>` は `/workspace` を指すシンボリックリンクです。パス検証では先にシンボリックリンクを解決したうえで、アクセス先が Home の境界内にあることを確認します。ディレクトリ構成は次のとおりです。

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

直下の `SOUL.md`、`MISSION.md`、`DESIGN.md`、`ConfidentialityPolicy.md` は [Agent Library](../agent-library/) が管理する永続ドキュメントです。最初の 2 つが責務と振る舞いを定義し、`DESIGN.md` は視覚的な制作物のデザインシステムを、`ConfidentialityPolicy.md` は Agent が Brain へ書き込む際の公開範囲（audience scope）の選択基準を定めます。`installed-skills/` には Agent の Skill が配置され、`sessions/` には PostgreSQL が採番する `10000` 以降の不変の数値 ID ごとに会話用 workspace が作られ、`jobs/` には Background Agent Job ごとの独立した workspace が作られます。

Agent Home のデータは、Worker インスタンスの削除やイメージ更新後も保持されます（再構築時に消去されるのは `/var/cache/ankole` のみです）。ただし、Docker のローカル volume は実行ホストに依存するほか、Cloudflare 環境で強制停止が発生した場合は最後の R2 バックアップ以降の書き込みが失われることがあります。ストレージ上の制約については [Worker](../worker-management/) を参照してください。

添付ファイル、公開ファイル、インストール済み Skill、Automation スクリプトは control plane 側のドライブに別途保管されます。ドライブの読み書きには `ankole-files` を、Pod のページ・Base テーブル・Applet の操作には control plane 経由で `ankole-pod` を使用します。一方、Job workspace と Codex スレッドは永続 Home 側に置かれ、各 Turn の開始前にドライブ上の内容と `installed-skills/` が同期されます。

Background Agent Job では、`skill_view` を通じて必要な Skill をオンデマンドで読み込みます。

## 反復的な Python のための Jupyter live kernel

変数をメモリに残したまま試行錯誤したい場合や、DataFrame をセル単位で確認しながら進めたい場合、あるいはステートフルな Python REPL が必要な場合、単発のシェル実行は不向きです。そうした用途には組み込みの `jupyter-live-kernel` Skill（`default_enabled: true`）が適しています。この Skill は [background job](../background-jobs/) として動作し、`hamelnb` をラップした Ankole 独自の Unix ソケットアダプター上に構築されています。Python カーネルがステップをまたいで起動し続けるため、毎回データを読み込み直すことなく、前のステップで定義した変数を次のステップからそのまま参照できます。

使い分けの目安は Skill 自身のガイドラインのとおりです。短く完結するステートレスな Python スクリプトなら単発のシェル実行を使い、Jupyter Notebook の編集や対話的なデータ分析・DataFrame 調査・API 探索を行いたい場合は `jupyter-live-kernel` を使います。システム Python、JupyterLab、`ipykernel`、および `hamelnb` ヘルパーはすべて Worker イメージにプリインストールされているため、新しい Agent でも追加セットアップなしですぐに利用できます。

## Background Agent Job の CodexRunner

`CodexRunner` は、すべての Background Agent Job を駆動する実行エンジンです。コード変更に限らず、トピック調査やドキュメント作成などの長時間タスクもすべて `CodexRunner` 上で動きます（選ばれる基準は作業ジャンルではなく「長時間・再開可能なライフサイクル」にあります）。ランナーは `app-server-client.ts` を通じて Codex app-server と通信し、ジョブ専用の workspace と実行時設定を準備します。

Console 画面上では対応するモデルプロファイルが **Background Agent Jobs** と表示されますが、データベース上の保存キーおよび API 上の名称は `coding` です。

## これらのパスの選択方法

運用者が管理すべき設定箇所はシンプルに整理されています。

- **Computer tools**（`command`、`read_file`、`apply_patch`）はすべての Worker に標準搭載されており、通常の会話 Turn で利用できます。
- **Jupyter live kernel** は `default_enabled` の Skill として提供されているため、[browser](../browser-automation/) Skill と同じく [Agent Library](../agent-library/) から有効・無効を制御します。対話的な Python 実行を許可したくない Agent では無効化してください。
- **CodexRunner** はすべての Background Agent Job を実行し、モデル呼び出しはすべて AIGateway を通ります。バックグラウンドジョブで通常とは別の provider やモデルを使いたい場合は Background Agent Jobs プロファイルを設定してください（未設定の場合はその Agent の `heavy` プロファイルが使われます）。

## 次のステップ

- これらのツールを実行し `/workspace` ファイルシステムを保持する Worker の詳細については、[Agent Computer Worker](../agent-computer-worker/) を参照してください。
- Jupyter Skill などの有効化モデルの仕組みについては、[Agent Library](../agent-library/) を参照してください。
- 内部キー `coding` に対応する Background Agent Jobs プロファイルの設定については、[Background Agent Jobs](../background-jobs/#モデル-provider-を選択する) を参照してください。
- Worker の信頼境界とセキュリティ強化手順については、[Security hardening](../security-hardening/) を参照してください。
