---
title: 運用のヒント
description: Ankole を運用するときに時間を節約できる、検証済みの短い手順 — ログの読み方、Agent のスコープ、secret のローテーション、詰まった Turn からの回復、model profile スロットの調整。
section: Guides
order: 308
---

ここには、単独のガイドにきれいに収まらないけれど頻繁に出てくる運用テクニックを集めました。各ヒントは短く、Ankole の実際の動作に根ざしており、初めて苦労して発見するよりもコストがかかりません。

## ローカルで pretty モードのログを読む

control plane は既定で構造化 JSON ログを出力します — 取り込みには向きますが読みにくい。ローカル開発では、devkit の pretty printer にパイプします：

```bash
bun run dev   # 1 つのターミナルで
bun run kit logs pretty < /path/to/log-stream   # またはログファイルをパイプする
```

本番では `ANKOLE_LOG_FORMAT=json` のままにし、書式設定はログインジェスターに任せます。pretty printer はローカル用の便利機能であり、本番設定ではありません。

## バグ調査の前にログレベルを絞る

`ANKOLE_LOG_LEVEL` の既定値は `info` です。特定の再現のために `debug` に下げ、終わったら戻します — `debug` のままのデプロイはうるさく、遅くなります。有効な値は `debug | info | warning | error` で、無効な値はブート時に拒否され、黙って無視されることはありません。

## ターミナルなしでアクティベーションコードを取得する

`bun dev`（または control-plane コンテナ）のターミナルが見えず、セットアップページがコードを要求する場合：

```bash
bun run kit show bootstrap-activation-code          # ローカル
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

データベースからコードを推測しないでください — セットアップフローが実際に使う source から読み取ります。

## model profile スロットをダイヤルとして扱う

10 個の profile スロットは、単なる「primary model とその仲間たち」ではありません。それぞれがダイヤルです：

- agent が主に短い質問に答えるときは **`primary`** を安い model に下げ、品質が cost より重要なら上げます。
- **`light`** には本当に安くて速いものをバインドします — これは高頻度・低リスクの経路のために存在します。
- agent が画像を見る場合にだけ **`vision_fallback`** を設定します。それ以外は未バインドのままにしてスロットを節約します。
- **`web_search`** と **`web_fetch`** は独立しています — agent が web に触れる必要があるときだけバインドします。

「遅い」と感じる agent は、実際に行っている仕事に対して重すぎる `primary` がバインドされていることがよくあります。

## 環境変数で credential をローテーションする

worker 環境の変更は、実行中の現在の Turn ではなく**次の Turn** で反映されます。つまり：

1. Console の **環境変数** に新しい値を入力して保存します。
2. 進行中の Turn を完了させます — その Turn はすでに自分の環境を持っています。
3. 新しいメッセージを送って、新しい値が反映されていることを確認します。

保存したときに実行中だった Turn から secret の変更を判断しないでください。その Turn は新しい値を見ません。

## 暗号化された値は必要なときだけ表示する

credential をローテーションするには置き換え値を入力します。古い値を確認するためだけに表示しないでください。問題を診断するために現在値を調べる必要があるときだけ **表示** を選択します。

## 詰まった Turn から回復する

詰まっているように見える Turn は、たいてい Ankole ではなく model か provider を待っています。何かをキャンセルする前に：

1. `/ai-gateway/conversations` で Turn の最近の model call を確認します — 長い間隔があれば provider がボトルネックです。
2. worker ログで実行中の tool call を確認します — 遅い tool は詰まった Turn のように見えます。
3. Turn が本当に固まっている場合だけ、agent の session を導くか、Turn をタイムアウトさせます。background job のキャンセルは `POST /background-agent-jobs/:id/cancel` で、実行中の Turn は完了まで走らせます。

積極的にキャンセルすることが、operator が半分だけ完了した副作用を作る方法です。

## binding を静かに無効化する

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` は*無効化*であり、ハード削除ではありません — 設定は回復可能なままです。agent を channel 内で沈黙させたいが設定は失いたくない場合（失効した credential、休暇、インシデント）に使います。再び有効にするには `PATCH` を使います。

## アップグレード前には毎回バックアップする

Helm のロールバックはデータベース migration を逆転しません。アップグレード前の 2 分間の `pg_dump` が、「ロールバックした」と「バックアップからリストアして 1 日失った」の違いです。コマンドは [バックアップとリストア](../backup-and-restore/) を参照してください。

## 正しい durable ドキュメントを調整する

Agent の責任が不明確なときは `MISSION.md` を編集します。コミュニケーションや判断が間違っているときは `SOUL.md` を編集します。web ページ、スライド、ドキュメント、チャートに一貫したビジュアルスタイルがないときは `DESIGN.md` を編集します。各ファイルは 1 つの関心事を所有するので、ビジュアルデザインシステムに振る舞いのルールを入れないでください。

## DingTalk では agent ごとに 1 つの bot

DingTalk は厳しい制約を強制します。agent ごとに有効な binding は 1 つ、`clientId` ごとに agent は 1 つです。スケールアウトするなら、agent ごとに 1 つの bot を計画してください。同じ agent への 2 つ目の binding は `dingtalk_binding_already_exists` で失敗し、別の agent での `clientId` 再利用は `dingtalk_app_already_bound` で失敗します。セットアップは [Quickstart](../quickstart/#chat-channels) を参照してください。

## Teams は常にパブリックエンドポイントを必要とする

Teams は長い接続ではなく、Bot Framework の webhook 呼び出しとして配信します。Teams の bot が動かなくなったら、最初に確認するのはパブリック HTTPS エンドポイントです。証明書の期限切れ、DNS の変更、ingress のダウンタイムはすべて「bot が返答しなくなった」ように見えます。Lark、Slack、DingTalk は長い接続を使うため、短時間のエンドポイントの瞬断を乗り切れますが、Teams は乗り切れません。

## 次のステップ

- Console のインターフェースリファレンスについては、[Console API リファレンス](../console-api/) を読んでください。
- 環境のつまみについては、[環境変数](../environment-variables/) を読んでください。
- kit のコマンドについては、[kit CLI リファレンス](../kit-cli/) を読んでください。