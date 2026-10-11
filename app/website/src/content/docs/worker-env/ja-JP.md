---
title: 環境変数
description: コマンドラインツール、MCP サーバー、Background Agent Job が必要とする環境変数を Console で設定する。
section: User guide
order: 10
---

Agent は、コマンドの実行、MCP サーバーの呼び出し、Agent Computer Worker での Background Agent Job の開始の際に、環境変数を必要とすることがあります。API key、token、サービス URL、その他同種の値には、Console の **Environment variables** を使ってください。

credential を Skill、Agent ドキュメント、チャットメッセージに入れないでください。

Agent と、Agent が起動するプログラムは、これらの変数を読み取れます。Agent が実行する各コマンドは、これらの値を含む新しい環境で始まり、Worker プロセスの環境を継承しません。Agent が使う必要がある credential だけを保存してください。LLM Providers、identity provider、chat channel の credential は、それぞれの Console ページで設定してください。

## 先にスコープを選ぶ

| 誰が変数を必要とするか | どこに設定するか | スコープ |
|---|---|---|
| site 全体の Agent | **Console → Environment variables → New site variable** | site デフォルト |
| 1 つの tenant の Agent | **Console → tenant を選択 → Environment variables → New tenant variable** | この tenant で site 値を override |
| 1 つの Agent | **Console → Agents → Agent を選択 → Environment variables** | その Agent で tenant と site の値を override |

Agent override、tenant 値、site デフォルトの順で解決します。override をクリアすると次に利用可能な値を使用します。どの scope にも値がない場合、変数を渡しません。

## site または tenant の変数を追加する

1. **Console → Environment variables** を開き、tenant を選択します。必要な scope の **New site variable** または **New tenant variable** を選びます。
2. 名前を入力します。英字、数字、アンダースコアを含められますが、数字で始めることはできません。例えば `MY_API_KEY` のようにします。
3. 値を入力します。API key、token、パスワードなど、機密性の高い値では **Store as secret** をオンにしたままにします。
4. オプションで、その変数を使う tool またはサービスを示すメモを追加します。このメモは Agent には渡りません。
5. 変数を保存します。

runtime は `PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX`、および `ANKOLE_` で始まる名前を予約しています。これらの名前はここでは設定できません。

## 1 つの Agent に変数を設定する

1. **Console → Agents** を開き、Agent を選択します。
2. **Environment variables** を見つけます。
3. 変数を追加するか、既存の変数で **Override** を選択します。
4. 値を入力して保存します。

このセクションは site、tenant、Agent の値を表示します。**Source** 列は有効な値の出所を示します。**Clear** は Agent override だけを削除し、tenant または site 値に戻します。

## 変数のタイプを理解する

WorkerEnv エントリはすべて運用者が追加した custom 値です。Ankole と Plugin は WorkerEnv を介して AppConfigure key を export しません。runtime の予約変数と binding credential は各 domain が管理します。

## 値の暗号化、表示、ローテーション

**Store as secret** は新しい変数で既定でオンです。Console は暗号化された値をリストでマスクしますが、Agent は実行時に元の値を受け取ります。

暗号化された変数を編集するとき、マスクを変更せずに保存すれば、保存された値が維持されます。credential をローテーションするには、新しい値を入力して保存します。先に古い値を表示する必要はありません。

現在の値を確認しなければならない場合にのみ **Reveal** を選択してください。**Store as secret** をオフにすると、Console は平文保存の確認を求めます。API key、token、パスワードでは暗号化をオフにしないでください。

## 変更が有効になるタイミング

変更は後続の Worker 作業に適用します。環境を取得済みの実行や workspace は以前の値を保持します。主モデル推論は control plane で実行し、WorkerEnv をそのプロセス環境として受け取りません。

Agent が期待する値を受け取らない場合、次の項目を順番に確認してください。

1. 名前が Skill、スクリプト、`bearer_token_env_var` 宣言と完全に一致すること。大文字と小文字を区別します。
2. site デフォルトより先に Agent と tenant の override を確認すること。
3. いずれかの scope に値が存在すること。
4. 変更後に新しい Worker 作業を開始すること。既存 workspace は取得済みの環境を保持します。

MCP ベースの Skill では、`bearer_token_env_var` に環境変数名だけを入れます。token はここに保存します。宣言契約は [MCP](../mcp/) を参照してください。
