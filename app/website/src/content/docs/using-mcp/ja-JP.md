---
title: MCP-backed Skill を使う
description: 有効化された Skill が mcporter を通じて Agent や Automation スクリプトを MCP サーバーへルーティングする仕組みを説明します。
section: Developer guide
order: 123
---

Ankole では、MCP サーバーを直接露出させるのではなく Skill の裏側で利用します。どの業務でどのツールを選び、返ってきた結果をどう扱うかというドメイン上の判断ルールは Skill が担い、そこで選ばれた特定の 1 ツールに対するプロトコル解決と呼び出し実行を固定バージョンの `mcporter` CLI が担います。

そのため、Agent 固有のドメイン連携を行う際に MCP サーバーを Agent へ直接登録しようとしないでください。代わりに、その MCP 依存関係を宣言した Skill を有効化します。Skill を無効化すれば、次回の実行からその依存関係も自動的に除外されます。

## Main Agent と Background Agent Job

ユーザーから依頼する際は、MCP の生ツール名を指定するのではなく、達成したい業務上のゴールをそのまま Agent に伝えてください。依頼を受けた Agent は該当する Skill を読み、呼び出すべき 1 つのツールを選定し、必要な場合にのみそのツールの最新スキーマを確認します。そのうえで、JSON の引数オブジェクトを標準入力（stdin）に渡して `mcporter` を実行します。

実行経路として、Main Agent は `command` ツールを使い、Background Agent Job は Codex ターミナルを使います。いずれの経路でも、MCP カタログ全体がモデルのネイティブツールとして展開されることはありません。

## Automation Job

Automation Job は実行時に Skill の自然言語手順書を読みません。そのため、`main.ts` を作成する Agent は、使用するツール名、引数、取得件数などの上限（bounds）、および結果の検証ロジックをあらかじめスクリプト内に明示的に組み込んでおく必要があります。

Automation の各実行試行（attempt）には、現在有効な Skill の MCP 依存関係と最新の Agent WorkerEnv が環境変数 `MCPORTER_CONFIG` を通じて渡されます。スクリプト内からは `Bun.spawn` で `mcporter` を起動し、子プロセスの stdin に JSON 引数を書き込み、終了コード（exit code）を確認してから stdout をパースしてください。なお、`~/.mcporter/mcporter.json` を独自に作成しないでください。

## Credential

Skill 側には `MCP_HTTP_TOKEN` のような認証情報の環境変数名だけを記述し、実際のシークレット値は [Environment variables](../worker-env/) に登録します。実行時に自動生成される設定ファイルにも環境変数名だけが書き出され、シークレットの生値が含まれることはありません。

必要な環境変数が未設定の場合、呼び出しはエラーで失敗します。トークンの実体をチャットメッセージ、Skill 本文、スクリプト、引数ファイル、シェルコマンド文字列の中に直接貼り付けないでください。

## 失敗と結果の範囲

不正な依存関係宣言やサーバー定義の競合がある場合は、モデルのコマンド実行や Automation スクリプトが動き出す前の準備段階でエラーになります。また、通信エラー、プロトコル違反、引数不正、MCP サーバー側のエラーが発生した場合は、`mcporter` がゼロ以外の終了コードで終了します。

コマンド出力ログや Automation 実行ログのサイズには上限があります。Skill 内で定義されているページネーション、データ鮮度、警告の扱い、および部分結果（partial-result）のルールに必ず従ってください。`mcporter` プロセスが終了コード `0` で正常終了したとしても、それだけで業務上必要なデータが漏れなく取得できたとは限らないためです。

## 参考

- 依存関係の宣言スキーマと実行時の挙動については、[MCP server reference](../mcp/) を参照してください。
- Skill の設計・執筆手順については、[Writing a Skill](../writing-a-skill/) を参照してください。
- 認証情報（シークレット）の登録方法については、[Environment variables](../worker-env/) を参照してください。
