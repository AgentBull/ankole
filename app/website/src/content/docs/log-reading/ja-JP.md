---
title: ログの読み方
description: Docker Compose または Kubernetes から Ankole のログを取得し、イベント名と context フィールドを使って障害箇所を特定します。
section: User guide
order: 57
---

Console に失敗した request しか表示されない場合や、Agent が返答しない場合は、ログを見れば障害が control plane、Worker、chat channel、LLM Provider のどこにあるかを判別できます。

Ankole はデフォルトで構造化 JSON ログを出力します。各レコードには重大度、イベント名、メッセージ、関連する context が含まれます。まずイベントを見つけてください。そのうえで、Agent UID、Provider ID、失敗理由を使ってレコードを絞り込みます。

## ログを取得する

Docker Compose:

```bash
docker compose logs --since 30m control-plane
docker compose logs --since 30m agent-computer-worker
```

Kubernetes:

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole logs deployment/ankole-agent-computer-worker --since=30m
```

リソース名は release 名に応じて変わることがあります。コマンドでオブジェクトが見つからない場合は、最初に `kubectl -n ankole get deployments` を実行してください。

問題を再現する前に、おおよその時刻、Agent、chat channel、ユーザーの操作を記録しておきましょう。そうすれば、プロセス起動時からすべて読むのではなく、短い時間帯だけを調べられます。

## 1 件のレコードを読む

```json
{
  "severity": "warning",
  "event": "signals_gateway.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity` はレコードの深刻度を示します。
- `event` は検索と集計に最適なフィールドです。
- `message` は読みやすい説明を示します。
- その他のフィールドは Agent、channel、Job、request を特定します。

エラーの前後にある警告と情報は、完全な流れを示すことがよくあります。最後の行だけをコピーしないでください。障害の前後の関連レコードを残しておきましょう。

## 役に立つ検索手順

1. 問題の時刻にログを限定します。
2. `error`、`warning`、または Console に表示されたエラーコードを検索します。
3. 関連するイベントを見つけたら、Agent UID、Provider ID、Worker ID、または chat adapter でフィルタリングします。
4. レコードと、**Console → Conversations** または **Background Agent Jobs** の状態を照合します。

ログには、復号された model credential、channel secret、Worker 認証キーは含まれません。ログをサポートに共有する前でも、ユーザーメッセージ、URL、その他の業務データが含まれていないか確認してください。

## 一時的にログの詳細度を上げる

`ANKOLE_LOG_LEVEL` は詳細度を制御し、デフォルトは `info` です。再現が難しい問題の場合は、一時的に `debug` に設定して、関連サービスを再起動できます。

再現後に元の値へ戻し、大量のログが出力され続けないようにしてください。

`ANKOLE_LOG_FORMAT` は `json` または `pretty` を指定できます。ログ収集システムを使っている場合は、そのシステムが期待する形式を維持してください。すべての変数については [デプロイ環境変数リファレンス](../environment-variables/) を参照してください。

現象別のチェックは [FAQ](../faq/) を参照してください。
