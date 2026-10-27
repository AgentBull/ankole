---
title: Signals
description: 永続イベント、ルーティングルール、共有会話の記録、および外部チャネルへの配信の仕組みを説明します。
section: Developer guide
order: 102
---

Signal は、Agent の Session に対して作業の実行を要求する永続イベントです。チャットメッセージ、スケジュールの定時起動、Automation の実行結果、各種の業務イベントなどを統一的に表現できます。Signal から Conversation や Message を参照することはできますが、汎用の業務イベントではこれらの参照は必須ではありません。

責務はドメインごとに明確に分かれています。イベントの受け入れと Signal Routing Rule は `Ankole.Signals`、共有発言の記録・外部イベントの観測・返信の配信は `Ankole.Conversations`、そして実際の Agent 実行は `Ankole.Sessions` がそれぞれ所有します。つまり「観測された事実」「起動のトリガー」「実行状態」をそれぞれの所有ドメインが独立して管理する構造になっています。

## Conversation と Message

Conversation は参加者間の共有履歴を保持します。ネイティブチャットも外部チャットも同じ Message モデルを使用し、発言者、本文、会話内の通し番号を記録します。外部チャットの Message については、`ExternalMessageRef` が外部 Provider 側のメッセージ識別子および生ペイロードとの紐付けを保持します。

外部 Conversation はテナント内の `provider_conversation_id` ごとに一意に管理されます。複数の Agent が同じ Conversation の発言履歴を共有しつつ、それぞれ独立した自身の Session とモデル履歴を持つことができます。また、Agent やルーティングルールを削除しても、記録された外部会話履歴自体はそのまま残ります。

外部からのイベント取り込みでは、`Conversations.Observe` が Provider の観測事実を受け入れ、`Conversations.External` が Message と外部参照を書き込みます。同一メッセージが再観測された場合は既存レコードが更新されます。リアクションの追加・変更では事実レコードのみを更新し、モデルの Turn は起動しません。Provider 側でメッセージ削除が発生した場合は Message の所有ドメインを経由して処理され、それに依存する実行側の状態も同一トランザクション内で整合的に更新されます。

## メッセージから Signal へ

各チャットアダプターは Provider からのリクエスト署名を検証し、メッセージ、リアクション、削除、インタラクティブ操作を共通形式へ正規化します。続いて `Observe` が Signal Routing Rule のフィルターとグループメッセージ方針を適用し、必要に応じて送信者の本人照合と受け入れ判定（アドミッション）を行います。

受け入れられた発言は Message として保存され、Agent による応答や処理が必要な場合は、同一トランザクション内でその Agent の Session に Signal が投入されます。フィルター条件に合致しないイベントは正常な no-op として完了し、リアクション単体で Agent が起動することもありません。

なお、Agent へのメンションがないグループ発言に対して `addressed_only` モードが設定されている場合は、受け入れ判定と通常の記録を省略できます。その後でその発言に対する明示的な返信メンションが行われた場合でも、参照元の Message は必要に応じて解決可能です。それ以外のグループ発言モードにおける介入判定の仕組みについては、[Ambient intervention](../ambient-intervention/) を参照してください。

## CloudEvents とルーティング

Signal Routing Rule は内部的に Binding として保存され、対象 Agent、アダプター、設定参照、フィルター条件、配信先を指定します。管理は Console から行え、ルールを無効化すると新規イベントの受け入れは止まりますが、記録済みの会話履歴が消去されることはありません。

構造化 JSON イベントを受け取るエンドポイントは次のとおりです。

```text
POST /signals/v1/cloudevents/:token
```

各イベントは必須の `specversion`、`id`、`source`、`type` に加え、任意の `subject`、`time`、`data`、拡張属性を持ちます。ルーティング先の単位としては、「固定の Conversation または Session」「`source` と `subject` の組み合わせごとの Session」「イベントごとに独立した Session」のいずれかを選択できます。同じ識別子を持つ再送イベントは重複排除されるため、同じトリガーが二重に発火することはありません。

外部から届いたイベントの `type` や `data` はあくまで外部入力データとして扱われ、内部の制御コマンドや信頼済みプロデューサーを詐称することはできません。システム内部で生成される Kernel イベントには、本来の所有ドメインだけが内部専用の来歴情報（provenance）を付与します。CloudEvents エンドポイントの作成・失効およびルールの設定は Console から行えます。

## provider の webhook と callback

外部 Provider 向けの Webhook ハンドラーは次のパスでリクエストを受け付けます。

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

宣言されたハンドラーが署名または認証情報を検証し、コントローラー側で `signals.webhook_handler` 契約と宣言済みの `kind` を確認します。なお、Signal アダプター本体のプラグイン契約は `signals.adapter` です。

一方、Agent 自身が動的に発行する生コールバック URL には `/webhooks/v1/event-callbacks/wh_<token>` が使われます。このケイパビリティ URL は登録済みコールバック経路への POST を許可しますが、リクエストボディの真偽までは保証しません。Signals はトークンのダイジェスト値のみを保存し、エンドポイントの状態判定と `webhook.received` イベント（または Automation Run の起動）を同一トランザクションでコミットします。ライフサイクルや Worker ブリッジの詳細については、[Webhook delegations](../webhook-delegations/) を参照してください。

## 配信

外部へのメッセージ送信では、`Conversations.Delivery` がまず永続的な送信意図（delivery intent）を保存してから、アダプターの `deliver` を呼び出します。送信前には実際の Provider 上の会話 ID・メッセージ ID が解決され、送信が確認された各 Message と外部参照は配信結果と同一トランザクションでコミットされます。

配信ステータスは `pending`、`sent`、`failed`、`expired`、`unknown` の 5 種類です。通信切断などで成否を確定できない場合は二重送信を防ぐため自動再送を行わず、`unknown` として記録します。オペレーターは永続化された送信意図と診断情報をもとに状態を確認できます。

実行制御と障害復旧については [Sessions](../sessions/) を、初期セットアップ手順については [Quick start](../quickstart/) を、3 つの概念の役割比較については [Conversations, Signals, and Sessions](../conversations-signals-sessions/) を参照してください。
