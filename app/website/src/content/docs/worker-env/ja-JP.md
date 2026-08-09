---
title: 環境変数
description: コマンドラインツール、MCP サーバー、Background Agent Job が必要とする環境変数を Console で設定する。
section: User guide
order: 10
---

Agent は、コマンドの実行、MCP サーバーの呼び出し、Agent Computer Worker での Background Agent Job の開始の際に、環境変数を必要とすることがあります。API key、token、サービス URL、その他同種の値には、Console の **Environment variables** を使ってください。

credential を Skill、Agent ドキュメント、チャットメッセージに入れないでください。

Agent と、Agent が起動するプログラムは、これらの変数を読み取れます。Agent が使う必要がある credential だけを保存してください。LLM Providers、identity provider、chat channel の credential は、それぞれの Console ページで設定してください。

## 先にスコープを選ぶ

| 誰が変数を必要とするか | どこに設定するか | スコープ |
|---|---|---|
| すべての Agent | **Console → Environment variables** | 既定で全 Agent が利用可能 |
| 1 つの Agent | **Console → Agents → Agent を選択 → Environment variables** | その Agent のみが利用可能。同名の値はグローバル値を上書き |

Agent の値をクリアすると、同名のグローバル値が再び有効になります。グローバル値が存在しない場合、Agent は変数を受け取らなくなります。

## すべての Agent に変数を追加する

1. **Console → Environment variables** を開き、**New variable** を選択します。
2. 名前を入力します。英字、数字、アンダースコアを含められますが、数字で始めることはできません。例えば `MY_API_KEY` のようにします。
3. 値を入力します。API key、token、パスワードなど、機密性の高い値では **Store as secret** をオンにしたままにします。
4. オプションで、その変数を使う tool またはサービスを示すメモを追加します。このメモは Agent には渡りません。
5. 変数を保存します。次の Agent Turn から利用可能になります。

runtime は `PATH`、`HOME`、`SHELL`、`TERM`、`LANG`、`BASH_ENV`、`ENV`、`WORKER_ID`、`DATABASE_URL`、`CODEX_UNSAFE_ALLOW_NO_SANDBOX`、および `ANKOLE_` で始まる名前を予約しています。これらの名前はここでは設定できません。

## 1 つの Agent に変数を設定する

1. **Console → Agents** を開き、Agent を選択します。
2. **Environment variables** を見つけます。
3. 変数を追加するか、既存の変数で **Override** を選択します。
4. 値を入力して保存します。

このセクションには、既定値、グローバル値、この Agent の値が表示されます。**Source** 列は、どの値が有効かを示します。**Clear** を選択すると、Agent の値を削除し、グローバル値または既定値に戻します。

## 変数のタイプを理解する

| タイプ | 意味 | 可能な操作 |
|---|---|---|
| Custom | 管理者が Console で追加した変数 | 編集または削除 |
| Declared | Ankole または有効な plugin が提供する変数 | 値の編集、または既定値へのリセット |

declared 変数の名前とデータ形式は固定されています。値がなく既定値もない変数は **Unset** として表示されます。

## 値の暗号化、表示、ローテーション

**Store as secret** は新しい変数で既定でオンです。Console は暗号化された値をリストでマスクしますが、Agent は実行時に元の値を受け取ります。

暗号化された変数を編集するとき、マスクを変更せずに保存すれば、保存された値が維持されます。credential をローテーションするには、新しい値を入力して保存します。先に古い値を表示する必要はありません。

現在の値を確認しなければならない場合にのみ **Reveal** を選択してください。**Store as secret** をオフにすると、Console は平文保存の確認を求めます。API key、token、パスワードでは暗号化をオフにしないでください。

## 変更が有効になるタイミング

変更は、既に開始された実行を変更しません。新しい値は、Agent の次の Turn、後の Background Agent Job 実行、後の Automation Job の試行で利用可能になります。

Agent が期待する値を受け取らない場合、次の項目を順番に確認してください。

1. 名前が、Skill、スクリプト、または `bearer_token_env_var` 宣言の名前と完全に一致していること。名前は大文字と小文字を区別します。
2. Agent が同名の値を持っているかどうか。Agent の値はグローバル値を上書きします。
3. 変数が **Unset** と表示されていないこと。
4. 変更後に新しい Agent Turn が開始されたこと。

MCP ベースの Skill では、`bearer_token_env_var` に環境変数名だけを入れます。token はここに保存します。宣言契約は [MCP](../mcp/) を参照してください。