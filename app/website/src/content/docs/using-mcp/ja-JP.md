---
title: MCP-backed Skill を使う
description: 接続を設定し、Agent Skill や Applet Action から MCP ツールを利用します。
section: Developer guide
order: 123
---

Agent に必要な Skill を有効化し、業務上の目的を伝えます。Agent は Skill を読んでツールを選び、シェルから MCPorter を呼び出します。メイン Agent と Background Agent Job は同じ制御プレーンのゲートウェイを利用します。

## アクセスの設定

GitHub、Lark、Linear の組み込み Toolkit は Pod の接続ページでアプリケーションを設定します。個人の権限が必要な操作では本人がアカウントを認可します。接続が複数ある場合は使用するものを指定してください。認可が不足すると、認可して再試行するためのリンクが返ります。

リモート HTTP Skill の `bearer_token_env_var` は Environment variables の値を参照します。制御プレーンがその値を読み取り、上流リクエストへ追加します。秘密情報は Worker のスナップショットから除外されます。ローカル `stdio` サーバーは宣言したコマンドで Worker 内に起動します。

## Applet からの利用

公開した Action のハンドラーで `AnkoleRuntime.mcp.call(tool, arguments, {server, connection})` を使います。チーム操作では `AnkoleRuntime.admin.mcp` を使い、ホストが呼び出し権限を管理します。自動化パネルから Job とソースを登録して Run を確認できます。Applet は Agent の Skill 環境を継承しません。

シェルで呼び出す場合は JSON を標準入力に渡し、明示的なタイムアウトを設定します。通信が成功しても業務エラー、ページング、部分結果を確認してください。部分的な書き込みでは返されたリソース ID を使い、残りの操作を行います。結果が不明な書き込みは上流の状態を確認してから再試行します。

[MCP リファレンス](../mcp/)、[Automation Jobs](../automation-jobs/)、[環境変数](../worker-env/)を参照してください。
