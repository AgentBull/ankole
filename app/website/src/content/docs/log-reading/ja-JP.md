---
title: ログの読み方
description: Docker Compose、Kubernetes、または Cloudflare 環境から Ankole のログを取得し、イベント名とコンテキストフィールドを手がかりに障害箇所を特定する方法を説明します。
section: User guide
order: 57
---

Console 上でリクエストの失敗しか分からない場合や、Agent から応答が返ってこない場合は、ログを確認することで、障害の原因がコントロールプレーン、Worker、チャットチャネル、LLM Provider のどこにあるかを切り分けられます。

Ankole はデフォルトで構造化 JSON ログを出力しており、各レコードには重要度（`severity`）、イベント名（`event`）、説明文（`message`）、関連コンテキストが含まれます。調査時はまず該当するイベントを特定し、そこから Agent UID や Provider ID、失敗理由（`reason`）を使ってレコードを絞り込んでいきます。

## ログを取得する

Docker Compose 環境の場合：

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

コントロールプレーンは Agent ごとに Worker コンテナを 1 つ作成します。2 行目のコマンドでコンテナ一覧を取得でき、`ankole.agent-uid` ラベルを見ればどの Agent に対応するコンテナかが分かります。

Kubernetes 環境の場合：

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

リソース名は Helm のリリース名によって変わることがあります。上記のコマンドで対象が見つからない場合は、先に `kubectl -n ankole get deployments` を実行して実際の名前を確認してください。Worker Pod の `ankole.io/installation` ラベルには、`worker.installation` を個別に上書きしていないかぎりリリース名が入ります。また、どの Agent の Pod かは `ankole.io/agent-uid` アノテーションで確認できます。

Cloudflare 環境の場合（`tools/deploy/cloudflare/agent-workers` ディレクトリで実行）：

```bash
bunx wrangler tail ankole-agent-workers
```

アダプターは、Worker の起動、停止、スナップショット作成のたびに JSON ログを 1 行ずつ出力します。

なお、Agent の Worker 自体が起動しない場合は、**Console → Workers** 画面で現在の状態とバックエンドから返された直近の失敗理由を確認できます。詳しくは [Workers](../worker-management/) を参照してください。

問題を再現テストする際は、あらかじめ発生時刻の目安、対象の Agent、チャットチャネル、行った操作を控えておくと便利です。プロセス起動時からの全ログを追う必要がなくなり、該当する短い時間帯だけを効率よく調査できます。

## 1 件のレコードを読む

```json
{
  "severity": "warning",
  "event": "signals.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity`：ログの重要度を表します。
- `event`：検索や集計の軸として最も適したフィールドです。
- `message`：人間が状況を把握しやすいように書かれた説明文です。
- その他のフィールド：対象の Agent、チャネル、Job、リクエストなどを特定するための識別情報です。

エラーレコードの前後に出力されている `warning` や `info` ログをたどると、障害に至るまでの流れが明確に見えてきます。末尾のエラー行だけを切り取るのではなく、発生前後の関連レコードもあわせて確認してください。

## 役に立つ検索手順

1. 問題が発生した前後の時間帯にログを絞り込みます。
2. `error`、`warning`、または Console に表示されたエラーコードで検索します。
3. 関連するイベントが見つかったら、Agent UID（その Agent の Worker ID でもあります）、Provider ID、またはチャットアダプター名でフィルタリングします。
4. 抽出したログレコードと、**Console → Conversations** や **Background Agent Jobs** 上のステータス表示を突き合わせます。

ログ内に復号済みのモデル認証情報、チャネルシークレット、Worker の認証情報が出力されることはありません。ただし、サポート窓口などへログを共有する前には、ユーザーのメッセージ本文や社内 URL、その他の業務データが含まれていないかを必ず確認してください。

## 一時的にログの詳細度を上げる

ログの出力レベルは環境変数 `ANKOLE_LOG_LEVEL` で制御でき、デフォルトは `info` です。再現しにくい事象を詳しく追いたい場合は、一時的に `debug` へ変更して対象サービスを再起動してください。

調査が終わったら忘れずに元の値へ戻し、大量のデバッグログが出力され続けないようにしてください。

設定可能なすべての環境変数については [デプロイ環境変数リファレンス](../environment-variables/) を、症状別の確認項目については [FAQ](../faq/) を参照してください。
