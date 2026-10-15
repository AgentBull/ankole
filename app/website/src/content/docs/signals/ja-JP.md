---
title: Signals
description: 永続イベント、ルーティングルール、共有会話の事実、外部配信。
section: Developer guide
order: 102
---

Signal は Agent の Session に作業を求める永続イベントです。メッセージ、定時の起動、automation の結果、業務イベントを表せます。Conversation と Message を参照できますが、汎用の業務イベントにこの二つは必須ではありません。

`Ankole.Signals` はイベントの受け入れと Signal Routing Rule、`Ankole.Conversations` は共有発言・外部観測・配信、`Ankole.Sessions` は実行を管理します。元の事実、刺激、実行状態はそれぞれの所有者が管理します。

## Conversation と Message

Conversation は共有履歴を保存します。ネイティブと外部のチャットは同じ Message モデルを使い、作者・内容・会話内の連番を記録します。`ExternalMessageRef` は外部の Message を provider の識別子と元の payload に結び付けます。

外部 Conversation は tenant 内の `provider_conversation_id` で一意です。複数の Agent が同じ Conversation の発言を共有し、各自の Session とモデル履歴を保持できます。Agent やルーティングルールを削除しても外部履歴は残ります。

`Conversations.Observe` が provider の事実を受け入れ、`Conversations.External` が Message と外部参照を書きます。再観測は同じ事実を更新します。reaction は事実だけを更新し、モデルの turn を起動しません。provider の削除は Message の所有者を通り、依存する実行の事実を同じトランザクションで更新します。

## メッセージから Signal へ

adapter は provider のリクエストを検証し、メッセージ・reaction・削除・action を正規化します。Observe は Signal Routing Rule のフィルターとメッセージ方針を適用し、必要な場合は本人確認の准入を行います。

受け入れたメッセージは Message になります。Agent の作業が必要なら、同じトランザクションでその Agent の Session に Signal を受け入れます。フィルターに合わない事実は成功した no-op です。reaction は Agent を起動しません。

Agent を指名しないグループメッセージでは、`addressed_only` が准入と記録を省略できます。後の明示的な返信参照に必要な元の Message は解決できます。[Ambient intervention](../ambient-intervention/) は他のグループ活動の判断を説明します。

## CloudEvents とルーティング

Signal Routing Rule は Binding として保存され、Agent、adapter、設定参照、フィルター、宛先を選びます。運用者は Console で管理します。無効にしたルールは新しい受け入れを止めますが、記録した会話の事実は削除しません。

構造化 JSON の入口は次のとおりです。

```text
POST /signals/v1/cloudevents/:token
```

イベントは `specversion`、`id`、`source`、`type` と、任意の `subject`、`time`、`data`、拡張を持ちます。ルールは固定の Conversation または Session、source と subject ごとの Session、イベントごとの Session を選べます。再配信は同じ識別子を使い、刺激を重複させません。

外部イベントの type と data は入力の事実です。内部の制御命令や信頼済み producer を宣言できません。kernel のイベントには実際の所有者が私有の来歴を付けます。Console で CloudEvents endpoint を作成・取消し、ルールを設定できます。

## provider の webhook と callback

provider の handler は次の入口を使います。

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

宣言された handler が署名または資格情報を検証します。controller は `signals.webhook_handler` と宣言された kind を確認します。Signal adapter の契約は `signals.adapter` です。

Agent が作る raw callback は `/webhooks/v1/event-callbacks/wh_<token>` を使います。能力 URL は記録した callback のルートを許可しますが、body の事実を認証しません。Signals は token の digest を保存し、endpoint の判断と `webhook.received` または automation run を一緒にコミットします。[Webhook delegations](../webhook-delegations/) に lifecycle と Worker bridge の説明があります。

## 配信

`Conversations.Delivery` は送信の意図を保存し、adapter の `deliver` を呼びます。送信前に実際の provider の会話・メッセージ識別子を解決します。確認された各 Message と外部参照は配信結果と一緒にコミットします。

状態は `pending`、`sent`、`failed`、`expired`、`unknown` です。確認できない結果は `unknown` として表示し、自動で再送しません。永続の意図と診断を使って確認できます。

実行と復旧は [Sessions](../sessions/)、設定は [Quick start](../quickstart/)、比較は [Conversations, Signals, and Sessions](../conversations-signals-sessions/) を参照してください。
