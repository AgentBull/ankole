---
title: ブラウザ自動化
description: Ankole の Agent が実際のブラウザセッションを操作する仕組み。browser Skill の役割、web_search / web_fetch との使い分け、有効化手順、および自前で Chromium を起動せず ankole-browser CLI を使う理由を説明します。
section: Guides
order: 305
---

`browser` Skill は、ページを開く、要素をクリックする、フォームに入力する、レンダリング後の DOM 状態を読み取る、スクリーンショットを撮る、稼働中のセッションに対して再現可能な Playwright スクリプトを実行するといった、実ブラウザ上での操作を Agent に行わせるための機能です。組み込みの単発ツールではなく [Skill](../agent-library/) として提供されており、実行時には [background job](../background-jobs/) として動きます。このページでは運用者向けに、この Skill の仕組み、有効化すべき場面、そしてブラウザ操作における重要な制約を説明します。

最初に押さえておくべき原則があります。**1 つの Agent セッションにつきブラウザの所有者は常に 1 つだけであり、その所有者は Agent ではなく runtime です。** Agent は Worker イメージがあらかじめ構成した `ankole-browser` CLI を通じてのみブラウザを操作します。自前で Chromium プロセスを起動したり、`chromium.connectOverCDP` を直接呼び出したりしてはいけません。それを行うと 2 つ目の所有者が生まれてしまい、セッション復旧の仕組みが機能しなくなるためです。

## ブラウザ自動化とは

Ankole のブラウザ自動化は、`app/library/skills/browser/SKILL.md` に同梱された組み込みの `browser` Skill（`default_enabled: true`）として実装されており、バックグラウンドジョブ用のランタイム（`ankole-runtime: background_job`）向けにタグ付けされています。Agent がこの Skill を使うと、元の会話 Turn とは分離された background job 内で処理が進み、runtime が管理する実際の Chromium セッションを操作します。

モデルがブラウザを使うべきかどうか判断する基準は、Skill 自身の description に明記されています。JavaScript レンダリング後の画面状態、UI 操作、スクリーンショット撮影、ログイン状態の維持、または再現可能な Playwright ワークフローが必要な場合にのみブラウザを使い、通常の情報検索や本文取得には [web_search](../web-tools/) または [web_fetch](../web-tools/) を優先します。

## ブラウザを使うべき場面

実ブラウザの操作はコストの高い経路です。単純な HTTP 取得では対応できない次のような場面に絞って利用してください。

- **レンダリング後の UI 操作**: クライアントサイド JavaScript の実行後や、クリック・スクロール・フォーム入力を行った後に初めて目的のデータが表示される場合。
- **永続的なログイン状態の維持**: runtime 側で認証済みのセッションを引き継ぐ必要があり、単発の HTTP リクエストではログイン状態を再現できない場合。
- **スクリーンショットの取得**: タスクの成果物として画面キャプチャが必要な場合や、人間が実際の表示崩れ・画面状態を目視確認する必要がある場合。
- **再現可能な Playwright ワークフロー**: 複数ステップにわたる一連のブラウザ操作を、安定したスクリプトとして繰り返し実行したい場合。

単に Web ページを探したり記事のテキストを読んだりしたいだけであれば、代わりに `web_search` や `web_fetch` を使ってください（`browser` Skill 内でもそのように案内しています）。これらのツールはより低コストかつ高速に動作し、ブラウザセッション枠も消費しません。

## 有効化の方法

ブラウザ自動化は Skill として提供されているため、個別のツールフラグではなく [Agent Library](../agent-library/) で有効・無効を切り替えます。出荷時の設定が `default_enabled: true` になっているため、制限を加えない限り、新しく作成した Agent では最初から利用可能です。制御は次の 2 段階で行います。

1. **テナントの既定値**: 出荷時は `default_enabled: true` です。テナント内のすべての Agent でブラウザ利用を許可する場合はそのままにします。
2. **Agent 単位の上書き**: ブラウザ操作を許可したくない特定の Agent だけ無効化したり、逆にテナント既定値をオフにしたうえで必要な Agent だけ有効化したりできます。

どちらの設定も、Console の library-capabilities 系ルートから変更できます（詳しくは [Console API リファレンス](../console-api/) を参照してください）。なお、Agent の `library-capabilities` を読み取るとその場で Skill の同期が走るため、古いスナップショットではなく現在のファイルシステムと照合された最新のレジストリ状態が返されます。

## runtime が注入するもの

ブラウザ設定を Agent 自身が選ぶことはありません。ブラウザジョブが始まる前に、runtime が必要な接続情報をすべて環境へ注入します（その内部構造は Agent からは不透明な値として扱われます）。

- runtime が管理するブラウザセッションへの**不透明な route**
- 操作対象となる準備済みの **browser material**（セッション実体）
- CLI の通信先となる **daemon socket**
- スクリーンショットなどの出力ファイルを保存する **artifact root**

Agent はこれらを意識することなく `ankole-browser` CLI を呼び出すだけです。`app/agent_computer/src/browser-runtime/index.ts` の `BrowserRuntime` クラスが materializer、daemon supervisor、および web-fetch アダプターを一括管理しており、セッションのライフサイクル管理はすべて runtime 側が担います。

## 制約:ブラウザの所有者は 1 つ

ブラウザを扱ううえで Agent が必ず守らなければならないルールが「単一所有者」の原則です。ブラウザの所有者はあくまで runtime であり、Agent は次の規則に従います。

- **あらゆるブラウザ操作に事前構成済みの `ankole-browser` CLI を使う**（`open`、`snapshot`、`click`、`fill`、`screenshot`、`batch`、および Playwright スクリプト実行用の `run`）。
- **Chromium を自前で直接起動しない。**
- **`chromium.connectOverCDP` を呼ばない。** また、プロファイル名、認証情報、provider 設定、CDP エンドポイント、control plane の内部識別子を詮索しない。

この制約を設けている理由は障害復旧にあります。runtime は daemon supervisor、materializer、およびセッション復旧経路を統合管理しています。もし Agent が独自に Chromium を立ち上げたり別経路で CDP 接続を開いたりすると、その接続は runtime の管理外に置かれます。すると、runtime がセッションの復旧・チェックポイント保存・破棄を行おうとした際に Agent 側の独自経路を把握・制御できず、セッションが不整合な状態に陥ってしまいます。事前構成済みの `ankole-browser` CLI だけが唯一の正規エントリポイントです。

## Agent がブラウザを操作する仕組み

`ankole-browser` CLI には、作業の粒度に応じた 3 つの実行モードが用意されています。

- **単発の CLI コマンド**: 画面構造の確認や 1〜2 手のシンプルな操作に使います（`open`、`snapshot -i`、`click @e2`、`fill @e4 "value"`、`screenshot` など）。
- **`batch`**: 手順がわかっている短い連続操作に使います。クォート付きコマンド列または `argv` 配列のリストを標準入力から受け取り、単発コマンドと同じパーサーで順番に実行します。
- **`run`**: ループや条件分岐、繰り返し抽出、ポップアップやダウンロードの制御、厳密な待機条件、複数データのメモリ保持が必要な処理では、ESM 形式の JavaScript ファイルを作成して `run` で実行します。`run` は通常の CLI コマンドが使っているのとまったく同じ物理ブラウザセッションへネイティブの Playwright オブジェクトを接続するため、CLI 操作とスクリプト実行の間で 1 つのセッションがそのまま共有されます。

特にこの `run` の挙動が重要です。`run` を実行しても 2 つ目のブラウザが立ち上がるわけではなく、runtime が所有する既存セッションが再利用されるため、Playwright スクリプトを書く場合でも「単一所有者」の原則がそのまま維持されます。

## オペレーターが触らないもの

Worker イメージには、`ANKOLE_BROWSER_CHROMIUM_EXECUTABLE`、`ANKOLE_BROWSER_DAEMON_SOCKET`、`ANKOLE_BROWSER_DAEMON_ENTRY`、`ANKOLE_BROWSER_RUNNER` といったブラウザ制御用の環境変数があらかじめ組み込まれています。これらの変数名を Console の **Environment variables** で上書きすることはできません。ブラウザ操作の手順や振る舞いをカスタマイズしたい場合は、Skill 側の定義を調整してください。

## 次のステップ

- ブラウザ機能を提供する Skill と有効化モデルの仕組みについては、[Agent Library](../agent-library/) を参照してください。
- 実ブラウザを起動しない軽量な検索・本文取得手段については、[Web tools](../web-tools/) を参照してください。
- ブラウザ処理の実行基盤となるバックグラウンドジョブについては、[Background Agent Jobs](../background-jobs/) を参照してください。
