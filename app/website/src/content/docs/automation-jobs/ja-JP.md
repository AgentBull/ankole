---
title: Automation Jobs
description: スケジュール、コールバック、外部イベントから Applet Action を実行し、保存された結果を確認します。
section: User guide
order: 22
---

Automation Job は、公開済み Applet の Action を Function Runtime で実行します。定型処理のたびに Agent のターンを起動する必要はありません。Job が設定と永続状態を保持し、Applet のコードが処理、同時実行方針、継続回数を定義します。

## 作成と接続

1. サーバーモジュールで `actions` を公開する Applet をデプロイします。
2. Applet の「自動化」パネルで Action を選び、個人用またはチーム用の Job を作成します。
3. スケジュール、コールバック URL、外部イベントソースを追加します。スケジュールは Cron と一定間隔に対応します。
4. 手動実行またはテスト通知を送り、Run の入力と結果を確認します。

Agent も `ankole-pod jobs` から同じ操作を行えます。コマンドの詳細は `ankole-pod --help` を参照してください。Applet の画面では `@ankole/applet-sdk` の `useAppletJobs()` と `useJobSources(jobID)` を利用できます。

## 実行する主体

個人用 Job は所有者の Human として実行され、本人または個人アシスタントがソースを管理します。チーム用 Job は Applet 所有者のサービス権限を使用し、管理にはページの編集権限が必要です。Applet をゴミ箱に移すと新しい実行を受け付けません。Job の削除時には所有するスケジュールとエンドポイントを削除し、外部イベントの関連付けを解除します。他の処理も使う共有サブスクリプションは残ります。

## 入力と結果

Action は `ctx.signal`、`ctx.job.config`、永続化される `ctx.state` を使用します。長い処理は `remainingMs()` と `continueSlice()` で分割します。外部ツールは `AnkoleRuntime.mcp`、チーム実行は対応する `AnkoleRuntime.admin` 能力から呼び出します。認証情報は Pod の接続ページで設定します。

自動化パネルには状態、開始・終了時刻、トリガー、結果、エラー、上限付きログが表示されます。入力とログは必要なときに展開できます。配信記録から Run を開け、入力が待機中の実行に統合された場合も確認できます。個人認可が必要なら表示されたリンクから認可して再試行します。部分的な書き込みエラーでは、返されたリソース ID を使って未完了の手順だけを再開します。

コードの更新は Applet を再公開します。実行間の状態はローカルファイルではなく `ctx.state` に保存し、Action が宣言する再実行方針に合わせて副作用を設計してください。

[スケジュール](../schedules/)、[Webhook 委任](../webhook-delegations/)、[自動化の構成例](../automation-blueprints/)も参照してください。
