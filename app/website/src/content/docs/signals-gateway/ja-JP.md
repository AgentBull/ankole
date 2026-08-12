---
title: SignalsGateway
description: 共有作業の入口レイヤー——chat、webhook、provider イベントが、ソースの事実を実行状態に書き換えることなく actor イベントになる仕組み。
section: Developer guide
order: 102
---

SignalsGateway は共有作業の入口です。chat メッセージ、webhook、provider イベント、スケジュールされたリマインダーが片側から入り、正規化された永続的な actor イベントがもう片側から出て、session を起こす準備ができています。このゲートウェイの仕事は、provider ごとに異なる形状を 1 つにまとめ、元の provider の事実をその後の実行から分離しておくことです。

このページは実際の入口経路、ユーザー向けルーティングルールの背後にある Signal Binding モデル、そしてミラーリングと wake の境界を示します。事実のソースは `Ankole.SignalsGateway` モジュールと、その `Ingress`、`Projection`、`Bindings` サブモジュールです。

## それが守る契約

すべての provider にわたって成立する 2 つの性質があり、それがこのゲートウェイを独立したレイヤーとして存在させる理由です。

- **ソースの事実は事実のまま。** ミラーされたエントリは、provider が現在どう見えるか（誰が、どの channel で、いつ、何を言ったか）を記録します。それは実行状態ではありません。agent の turn は、これらの事実の投影に対して実行されるのであって、事実そのものに対してではありません。
- **wake は条件的。** 受け入れられた事実のすべてが actor を起こすわけではありません。フィルタされた signal は成功した no-op です（`status: :filtered`）。actor ランタイムが起動されるのは、受け入れられた事実が実際に新しい actor イベントを生み出したときだけです。

この分離が重要なのは、provider の挙動がそれぞれ異なり、再試行や再配信をし、agent が見るべきだがそれに基づいて行動すべきではないイベントを送るためです。ゲートウェイがそのばらつきを吸収し、actor ランタイムが 1 つのきれいな入力ストリームを見るようにします。

## 入口パイプライン

すべてのインバウンド事実は、provider に関係なく同じ固定パイプラインを進みます。

1. **ルーティングルールを解決する。** ゲートウェイは `agent_uid` と `binding_name` で内部の Signal Binding を検索します。ルールがなければルートもなく、そのためその事実は拒否されます。
2. **事実を構築する。** provider ネイティブのペイロードは、`FactNormalizer` を通じて型付きの事実（エントリ、リアクション、アクション、またはライフサイクル）に正規化されます。"delete" や "recall" のような provider 固有の名前は、1 つの actor 向けの種類に統合されます。
3. **ルーティングフィルタを適用する。** ルールのフィルタが、この事実が範囲内かを判断します。一致しない場合は `{:ok, %{status: :filtered}}` を返します。これは成功であり、エラーではありません。
4. **受け入れてミラーする。** 受け入れられた事実は channel ミラーを upsert し、エントリ投影を書き出します。ここで provider の事実が永続的な行になります。
5. **妥当なときは actor イベントを引き渡す。** 受け入れられた事実が actor を起こすべき場合、`ActorEvent` 行が session キューに追加されます。リアクションは例外で、ミラーのみを更新し、actor イベントを決して作りません。

受け入れに至るロックの順序は固定されています。channel、次に session、そして actor イベントです。同じ channel 上の並行する事実は、決定的に解決されます。

## インバウンド事実の種類

ゲートウェイは `Ingress` を通じて 4 つの具体的な種類を受け入れ、それぞれが正規化された actor 向けの契約に対応します。

- **エントリ（entry）**。channel に届くメッセージまたは投稿です。主要な wake 経路です。IM エントリポリシーは、返信されていないグループメッセージが `may_intervene` イベント（agent が発言してよい）になるか、`addressed` イベント（agent が直接呼ばれた）になるかを決めます。介入の判断がどう振る舞うか、返信の帰属、channel の常設指示については [アンビエント介入](../ambient-intervention/) を参照してください。
- **エントリ削除（entry removed）**。provider の削除または recall です。actor 向けの契約は常に `signal.entry.removed` であり、provider ネイティブのライフサイクル名は診断用にだけ残されます。
- **リアクション（reaction）**。既存のエントリに対する emoji または投票の変化です。ミラーのみを更新し、actor を決して起こしません。ゲートウェイが一度もミラーしていないエントリへのリアクションは、エラーではなく無視されます（`:ignored_unknown_entry`）。
- **アクション（action）**。カードのボタンクリックのような、provider が発生させるインタラクションです。返信インタラクションの重複排除を経ます。重複クリックは `:duplicate_action`、古いものは `:stale_action`、受け入れられたものは `signal.action.invoked` イベントになります。

## channel、エントリ、リプライモード

**channel** は、エントリが存在する provider 側のコンテナです。IM のダイレクトメッセージまたはグループ、webhook エンドポイント、イシュー、アラートのストリームなどです。channel の行は純粋な外部事実のミラーであり、provider ネイティブの channel id をキーにするため、イベントごとに挿入ではなく upsert で書き込まれます。これは `reply_mode`（`:none`、`:channel`、`:entry`）を記録し、アウトボックスはこれを読んで、返信を新しい channel 投稿として送るか、特定のエントリへのスレッド返信として送るかを決めます。

**エントリ** は channel 内の 1 単位のコンテンツです。1 つのメッセージ、1 つの投稿、1 つのイベントです。エントリ投影こそが agent の turn が読むものであり、それは actor イベントでもなく、ソースのペイロードの逐語的なコピーでもありません。

## ルーティングルールモデル

signal ルーティングルールは Signal Binding として保存され、1 つの provider アダプタを、運用者が選んだ名前で 1 つの Agent に接続します。ルールは Agent に属し、Console の範囲のルートで管理されます。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/signal-adapters` | この導入インスタンスが宣言したアダプタを一覧表示する |
| `GET` | `/signal-bindings` | ルーティングルールを一覧表示する（`?agent=` で Agent を絞り込み） |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | ルーティングルールを作成または置換する |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | ルーティングルールを更新する |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | ルーティングルールを削除する |

ルールは、使うアダプタ、設定の参照、フィルタルール、グループメッセージポリシー、`enabled` フラグ、`confidential_memory` フラグを持ちます。ルールを無効にすると、新しい事実がその Actor を起こすのを止めますが、ルール自体は削除しません。利用できないルールは `unavailable_reason` を記録し、運用者が停止の理由を確認できるようにします。

アダプタはハードコードされていません。起動時に `signals_gateway.adapter` 契約の下でプラグインレジストリから解決されるため、利用できる provider の集合は、この導入インスタンスのプラグインが宣言するものになります。どの宣言も提供しないアダプタ id へのリクエストは `signal_adapter_not_found` を返します。

## Provider の webhook 入口

イベントをプッシュする provider は、1 つの正面玄関からゲートウェイに到達します。

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

このルートは、あらゆる認証パイプラインの外側に意図的に置かれています。session も、CSRF も、bearer token も、Accept ネゴシエーションもありません。provider が送るヘッダは provider 次第だからです。provider を認証するのは宣言された handler の仕事です。Bot Framework の JWT、Graph の `clientState`、または provider が署名に使うものなどです。

コントローラはルーティングだけを行います。宣言された `signals_gateway.webhook_handler` プラグインを解決し、handler が宣言した `kind` のホワイトリストを強制し、handler の応答命令を描画します。未知の handler や未宣言の kind は、ペイロードをエコーバックせず `404` を返します。handler が失敗した場合は、汎用メッセージ付きの `500` を返します。正規化された事実で `Ingress` を呼ぶのは handler 自身です。

## Agent が作成する webhook 委譲

Agent が作成したコールバック能力は、別の入口を使います。

```text
POST /webhooks/v1/event-callbacks/wh_<token>
```

このパスは provider handler を使いません。URL 自体が、それを作成した Agent session への 1 つの wake-up パスを認可します。ボディ内の事実は認証しません。

SignalsGateway は token の digest だけを保存します。エンドポイントをロックし、one-shot または standing の配信セマンティクスを適用し、同じ PostgreSQL トランザクション内で `webhook.received` を追加します。Worker はその後、信頼できないデータ境界の内側で、有界なヘッダとボディデータを投影します。Agent は結果に影響するアクションの前に、現在の外部システムを読み取ります。

エンドポイントの作成、一覧、キャンセルのコマンドは、turn-local の Worker ブリッジを使います。Console はエンドポイントの一覧とキャンセルができますが、作成はできず、コールバック URL も開示しません。ユーザーフロー、GitHub のライフサイクル、配信契約、運用上の上限は [Webhook 委譲](../webhook-delegations/) を読んでください。

## アウトボックス: 返信が発信されていく

インバウンドはゲートウェイの半分です。もう半分はアウトボックスで、agent の返信を provider 側の送信に変えます。アウトボックスは channel の `reply_mode` を読んで送信操作（channel 投稿か、スレッド化されたエントリ返信）を選び、イングレスと同じアダプタ契約を通ります。agent が turn 中に確定（commit）した副作用はこの経路で配信され、それらの永続的な記録は、それらを生んだ actor イベントとともに存在し、ライブの worker の中にはありません。

## SignalsGateway がそうでないもの

それは provider クライアントではありません。すべてのチャットプラットフォームに対して接続を開いたままにすることはなく、それはアダプタとその長接続 worker の仕事です。任意の作業のためのキューでもありません。session 上の actor 向けイベントのためのものだけです。agent の実行が置かれる場所でもありません。actor イベントが追加されれば、wake して turn を実行するのは Actor Runtime の仕事です。ゲートウェイの境界は、provider の事実を永続的な actor の入力に変換し、actor の返信を provider への送信に戻すことです。

## 次のステップ

- 起こされた actor イベントがどう実行されるかは、[AIGateway API](../ai-gateway/) と [アーキテクチャ概観](../architecture/) を読んでください。
- Channel Provider とルーティングルールの設定は [クイックスタート](../quickstart/) を読んでください。
