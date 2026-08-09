---
title: ブラウザ自動化
description: Ankole の Agent が実際のブラウザセッションを操作する仕組み——browser Skill、web_search/web_fetch の代わりに使うべき場面、有効化の方法、そして Agent が Chromium を自前で起動せず、事前設定済みの ankole-browser CLI を使わなければならない理由。
section: Guides
order: 305
---

browser Skill は、Agent が実際のブラウザ作業——ページを開く、クリック、入力、レンダリング後の状態の読み取り、スクリーンショット、実行中のセッションに対する再現可能な Playwright スクリプトの実行——を行うためのものです。これは [Skill](../agent-library/) であり、組み込み tool ではなく、[background job](../background-jobs/) として実行されます。このページはオペレーター視点の説明です。この Skill が何か、いつ有効にするか、Agent がブラウザで何をしてもよく、何をしてはいけないか。

決定的な性質を先に述べます。Agent セッションごとにブラウザの所有者は 1 つだけであり、それは Agent ではなく runtime です。Agent は、worker イメージが注入する事前設定済みの `ankole-browser` CLI を通じてブラウザを操作します。Chromium を自前で起動したり、`chromium.connectOverCDP` を呼んだりしてはいけません——それらは 2 つ目の所有者を作り、セッション復旧を迂回するからです。

## ブラウザ自動化とは

Ankole におけるブラウザ自動化は `browser` Skill であり、`app/library/skills/browser/SKILL.md` に同梱されています。これは builtin Skill（`default_enabled: true`）で、background-job runtime 用（`ankole-runtime: background_job`）にタグ付けされています。Agent がこれを呼び出すと、作業は background job の中で実行され、元の Turn から分離され、runtime が所有する実際の Chromium セッションを対象とします。

Skill 自身の description が、model が使うかどうかを判断するための契約です。作業がレンダリング後のページ状態、インタラクション、スクリーンショット、永続的なログイン状態、または再現可能な Playwright ワークフローに依存する場合はブラウザを使い、通常の探索とテキスト抽出には [web_search](../web-tools/) または [web_fetch](../web-tools/) を優先してください。

## ブラウザを使うべき場面

ブラウザは heavyweight の経路です。fetch では不十分な場合にのみ使ってください。具体的には:

- **レンダリング後のインタラクション**——JavaScript の実行後、またはクリック、スクロール、フィールドへの入力後にのみ、ページが必要なデータを表示する場合。
- **永続的なログイン状態**——runtime が既に認証済みのセッションが必要で、単純な fetch ではログインを再現できない場合。
- **スクリーンショット**——タスクにビジュアルな成果物が必要な場合、または人間がページの状態を見る必要がある場合。
- **再現可能な Playwright ワークフロー**——同じ複数ステップのブラウザ作業を複数回実行する必要がある場合。

ページを見つけたいだけ、またはテキストを読みたいだけであれば、代わりに `web_search` か `web_fetch` を使ってください。browser Skill 自身もそう述べています。それらの tool はこの Skill の外にあり、レンダリング後のインタラクション、ログイン状態、スクリーンショット、ブラウザ側のコードが不要な場合は、それらを優先すべきです。fetch はより安く、より速く、ブラウザセッションを消費しません。

## 有効化の方法

ブラウザは Skill なので、tool フラグではなく [Agent Library](../agent-library/) を通じて有効にします。`default_enabled` が `true` のため、新しい Agent は、狭めない限り最初からブラウザを利用できます。2 つの層:

1. **インスタンス全体の既定値**——Skill は `default_enabled: true` で出荷されます。すべての Agent がブラウザを使えるようにするには、そのままにします。
2. **Agent 単位の上書き**——ブラウザを持つべきでない Agent では狭め、以前狭めた Agent では広げます。

どちらの層も Console の library-capability ルートで設定します。[Console API リファレンス](../console-api/) に説明があります。Agent の `library-capabilities` を読み取ると Skill 同期がトリガーされるため、表示されるのは現在のファイルシステムと対帳されたレジストリであり、古いスナップショットではありません。

## runtime が注入するもの

Agent がブラウザ設定を選択することはありません。ブラウザ job が開始される前に、runtime が job に必要なすべてを注入し、その値は Agent にとって不透明です。

- runtime が所有するブラウザセッションへの**不透明な route**
- **最終的な browser material**（Agent が操作する準備済みセッション）
- CLI が通信する**daemon socket**
- スクリーンショットやその他の出力のための**artifact root**

Agent はこれらを `ankole-browser` CLI を通じて使います。`app/agent_computer/src/browser-runtime/index.ts` の `BrowserRuntime` クラスが materializer、daemon supervisor、web-fetch adapter を所有するため、ブラウザセッションのライフサイクルは runtime の責任です。Agent の責任は CLI を呼び出すことです。

## 制約:ブラウザの所有者は 1 つ

これは Agent が破ってはいけない規則です。runtime がブラウザの所有者です。Agent は:

- **すべての操作に事前設定済みの `ankole-browser` CLI を使う**——open、snapshot、click、fill、screenshot、batch、そして Playwright スクリプトには `run`。
- **Chromium を自前で起動しない。**
- **`chromium.connectOverCDP` を呼ばない**。profile 名、credential、provider 設定、CDP エンドポイント、control-plane 識別子を探すこともしない。

理由は復旧です。runtime は daemon supervisor、materializer、セッション復旧パスを所有します。2 つ目のブラウザ所有者——Agent が起動した Chromium や、Agent が開いた CDP 接続——はそのパスの外にあります。runtime がセッションを復旧、checkpoint、または破棄しようとするとき、Agent の側の channel を見ることも制御することもできないため、セッションは一貫性のない状態で終わります。事前設定済みの CLI は唯一の、所有されたエントリポイントであり、Agent が触るべき唯一のものです。

## Agent がブラウザを操作する仕組み

`ankole-browser` CLI は Agent に 3 つの実行面を提供し、作業の形状に応じて選びます。

- **短い CLI コマンド**——探索と 1、2 個の決定的なアクション用。`open`、`snapshot -i`、`click @e2`、`fill @e4 "value"`、`screenshot`。
- **`batch`**——既知の短いシーケンス用。引用符付きコマンドまたは argv 配列の配列を stdin から受け取り、単一コマンドと同じパーサーを適用します。
- **`run`**——ループ、分岐、繰り返し抽出、popup や download の調整、正確な待機、複数の値を memory に保持する必要があるタスクには ESM JavaScript ファイルを使います。`run` は、CLI コマンドが使うのと同じ物理ブラウザセッションにネイティブの Playwright オブジェクトを接続するため、スクリプトと CLI ステップは 1 つのセッションを共有します。

最後の点が重要です。`run` は 2 つ目のブラウザを開きません。runtime が所有するセッションを再利用するため、単一所有者の規則は Playwright スクリプト内でも成立します。

## オペレーターが触らないもの

worker イメージがブラウザの環境変数を設定します。それには `ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`、`ANKOLE_BROWSER_CHROMIUM_ARGS_JSON`、`ANKOLE_BROWSER_DAEMON_SOCKET`、`ANKOLE_BROWSER_DAEMON_ENTRY`、`ANKOLE_BROWSER_CLI`、`ANKOLE_BROWSER_NODE`、`ANKOLE_BROWSER_RUNNER` が含まれます。これらの名前を Console の **Environment variables** で上書きすることはできません。ブラウザの振る舞いを変える必要がある場合は Skill を変更してください。

## 次のステップ

- ブラウザを有効にする Skill と有効化モデルについては、[Agent Library](../agent-library/) を読んでください。
- より軽い代替——ブラウザを使わない検索とテキスト fetch——については、[Web tools](../web-tools/) を読んでください。
- ブラウザを実行する Job については、[Background Agent Jobs](../background-jobs/) を読んでください。