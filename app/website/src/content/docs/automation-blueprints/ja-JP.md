---
title: 自動化ブループリント
description: トリガーを Agent session、automation job、background job、signal ルーティングルールと組み合わせる実践パターンと、Workflow との使い分けを説明します。
section: Guides
order: 309
---

トリガーと処理先を別々に選びます。スケジュール、Checkback、コールバック、Connector イベントが CloudEvents を供給し、Agent は判断や会話、Applet Action は定型処理を担当します。同じソースを複数の処理先に関連付けることもできます。

## よく使う構成

| 目的 | 構成 | 動作 |
| --- | --- | --- |
| 毎日の報告 | Agent スケジュール、タスク、送信先 | 情報を集めて要約を送信 |
| 頻繁な状態確認 | Applet Job と所有スケジュール | モデルを起動せず条件を確認 |
| 一度だけの再確認 | Agent Checkback | 指定時刻に元の会話を再開 |
| 外部の変更を受信 | Connector サブスクリプションまたはコールバック | 関連付けた Job または Agent を起動 |
| 長時間の調査 | Agent スケジュールと Background Agent Job | 独立して調査し、元の会話に報告 |
| 静かなチャンネル監視 | 記録専用のチャット接続とスケジュール | 普段は記録し、定期的に要約 |

## 定型監視を作る

確認処理を Applet Action として公開し、自動化パネルで Job、設定、ソースを登録します。入力は `ctx.signal.data`、カーソルや前回値は `ctx.state` を使います。外部操作は `AnkoleRuntime.mcp` で呼び出し、接続が複数ある場合は使用する接続を指定します。

通常時、変化時、上流エラー時をテストして Run の入力と結果、ログを確認します。通知が必要なら Action から対象プラットフォームのメッセージ機能を明示的に呼び出してください。成功した Run が自動的にチャット通知を送るわけではありません。

毎回解釈や文章作成が必要なら Agent、コードで判断できるなら Applet Job を選びます。[Workflow](../workflows/) は一つのターン内の有限な並列判断、[Background Agent Job](../background-jobs/) は長い Agent 作業に適しています。

[Automation Jobs](../automation-jobs/)、[スケジュール](../schedules/)、[Webhook 委任](../webhook-delegations/)を参照してください。
