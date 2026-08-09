---
title: Webhook 委譲
description: Agent または決定性スクリプトが、ポーリングなしで低頻度の外部イベントを待てるようにします。
section: User guide
order: 23
---

webhook 委譲を使うと、Agent は Ankole の外で起こる作業を待つことができます。外部システムがイベントを検出し、短期間有効な Ankole コールバック URL を呼びます。デフォルトでは、Ankole は受領を保存し、委譲を作成した session を起こし、Agent が検証した結果を元の chat ルートを通じて返します。決定性スクリプトが先に受領を消費しなければならない場合は、エンドポイントで automation job を指定することもできます。

コールバックは wakeup の能力です。リクエストボディが真実であることの証明ではありません。Agent は、事実を報告するか認可された変更を行う前に、現在の外部オブジェクトを読み取ります。

最初にサポートされたシナリオは GitHub repository webhook です。EventBridge と Flink は実装されていません。

## 使う場面

webhook 委譲は、外部システムがうまくフィルタできる低頻度のイベントに使います。

- GitHub の issue、comment、pull request、または workflow run
- 同じ会話を 1 回だけ起こすべきイベント
- 繰り返しの処理が安全な常設の監視

高頻度のストリーム、ポーリングループ、汎用イベントバスには使わないでください。検出は外部システムに置いたままにし、判断、memory、返信は Ankole に置きます。

リクエストでは、結果、権限、イベント集合、終了時刻を説明してください。たとえば:

> `owner/repository` の pull request を金曜まで監視します。必須チェックが失敗したら知らせてください。報告する前に、現在の pull request と check の状態を検証します。私が依頼しない限り、コードを変更しないでください。

GitHub Skill がセットアップと復旧の詳細を所有します。

## 要件

Agent が GitHub 委譲を作成する前に:

1. 公開 HTTPS ホストを Ankole の control plane にルーティングします。ホストは `/webhooks/v1/event-callbacks/*` を保持しなければなりません。
2. Agent に対して、公開の **GitHub** Agent Plugin と、それが必要とする Skill を有効にします。GitHub はデフォルトで無効です。
3. Agent の WorkerEnv に `GITHUB_TOKEN` を追加します。token は対象 repository への読み取りアクセスと、repository webhook への書き込みアクセスを必要とします。
4. 能力または WorkerEnv の設定を変更した後、新しい Agent turn を開始します。

エンドポイントのコマンドは、アクティブな turn 中の Main Agent にだけ使えます。Background Agent Job は turn-local の webhook 接続を持ちません。

## ライフサイクル

1 つの稼働中の GitHub 委譲は、1 つの repository、1 つの正確なイベント集合、1 つの期限、1 つの Ankole エンドポイント、1 つの GitHub hook、1 つの照合 checkback を持ちます。

1. Agent が現在の会話用のエンドポイントを作成します。
2. GitHub hook を作成する前に、永続的な checkback を作成します。これにより、クリーンアップと照合の義務が記録されます。
3. コールバック URL で repository hook を作成します。GitHub は `ping` を送ります。
4. GitHub の delivery ログを読み、`ping` が成功したことを確認します。
5. 一致する delivery が届くと、Ankole はエンドポイントの判定と、`webhook.received` ActorEvent またはバインドされた automation job の run を、成功を返す前に 1 つの PostgreSQL トランザクションで確定します。
6. 直接経路では、起こされた Agent が受領を信頼できない入力として扱います。バインドされた automation job は、イベントを発火する前に同じ規則を適用しなければなりません。
7. 照合は、hook、イベント集合、失敗した delivery、現在の GitHub オブジェクト、期限、次のチェック時刻を確認します。
8. 撤去（teardown）は、Ankole のエンドポイントと checkback をキャンセルする前に GitHub hook を削除します。

GitHub は失敗した webhook delivery を自動的に再試行しません。GitHub Skill が直近の delivery を確認し、失敗がまだ意味を持つときに GitHub の redelivery API を使います。

## one-shot と standing のエンドポイント

| モード | 契約 | 用途 |
|---|---|---|
| `one_shot` | 同時の delivery は 1 つだけがエンドポイントを claim できる。後の delivery は成功の no-op を受け取る | 1 回だけ期待する受領 |
| `standing` | 受け入れられた delivery ごとに、選択されたコンシューマ向けのレコードを 1 つ作成する。配信は少なくとも 1 回（at least once）で、重複は見える | 低頻度のエッジイベント |

standing の配信は複数のコンシューマレコードを作成できます。コンシューマは現在の外部状態を権威として使い、繰り返しの処理をべき等に保ちます。

## 決定性コンシューマを使う

Agent は、エンドポイントを作成するときに `--automation-job-id <id>` を渡せます。受け入れられた `webhook.received` エンベロープは、会話を直接起こす代わりに、永続的な automation job の run の `context().event` になります。スクリプトは無関係な受領を静かに破棄するか、決定性のチェックを完了した後で `emitEvent` を呼べます。

受領は信頼できない入力のままです。スクリプトは、結果に影響する事実を権威あるソースで検証し、繰り返しの配信を無害にしなければなりません。配信に memory、判断、または会話が必要な場合は、直接の Agent wake を使ってください。導入は [Automation Jobs](../automation-jobs/) を、SDK と失敗契約は [Worker CLI の能力](../cli-capabilities/) を読んでください。

## Console

Console で **Webhooks** を開き、Agent と session ごとにエンドポイントを確認できます。ページには、ラベル、モード、状態、期限、ソースルートが表示されます。コールバック URL、平文 token、保存された digest は表示されません。

Console はエンドポイントの一覧とキャンセルができます。作成はできません。作成には現在の会話ルートが必要なので、アクティブな Agent turn に属しています。

緊急の credential 失効が必要なときは、Console からキャンセルしてください。これは外部の GitHub hook を削除しません。その hook は別途削除してください。通常の撤去では、Agent にまず GitHub hook の削除を依頼してください。

## セキュリティと配信の制限

- Ankole は完全なコールバック URL を一度だけ返します。PostgreSQL はその SHA-256 digest のみを保存します。
- Ankole のリクエストログは `/webhooks/v1/event-callbacks/*` を `/webhooks/v1/event-callbacks/[REDACTED]` に置き換えます。ingress、proxy、CDN にも同じパスを秘匿化するよう設定してください。
- コールバックボディの上限は 1 MiB です。過大なリクエストは、通常のボディパーサーが動く前に `413` を返します。
- Ankole はイベントメタデータのヘッダだけを保持します。`content-type`、`x-hub-signature-256`、`x-github-*`、`ce-*` です。authorization と一般的なリクエストヘッダは破棄します。
- Agent が見るのは、信頼できないデータ境界の内側の有界な受領です。外部データ内のリテラルな終了タグはエスケープされます。
- コールバック URL は wakeup のみを認可します。署名ヘッダが存在しても、業務上の効果を認可しません。

## トラブルシューティング

- **Agent が GitHub Skill を見つけられない:** この Agent に対して GitHub Agent Plugin と Skill が有効になっているか確認し、新しい turn を開始してください。
- **GitHub がコールバックに到達できない:** 公開 HTTPS 証明書、DNS、ingress ルート、`/webhooks/v1/event-callbacks/*` の転送を確認してください。
- **hook は存在するが Agent の返信がない:** GitHub の delivery ログ、Console のエンドポイント状態、Worker の準備状況、永続的な actor イベント、出方向の chat 配信を確認してください。
- **GitHub が `413` を報告する:** 選択したイベントのペイロードが 1 MiB を超えています。GitHub 側でイベントの形状を絞るか、別の検出器を使ってください。
- **同じイベントが Agent を 2 回起こす:** standing エンドポイントではこれは有効です。Agent は現在の GitHub 状態を再読み取りし、繰り返しの処理を安全にしなければなりません。
- **セットアップ中にコールバック URL を失った:** 一致する GitHub hook を削除し、古いエンドポイントと checkback をキャンセルし、置き換えを 1 つ作成してください。

入口の owner とトランザクション境界は [SignalsGateway](../signals-gateway/) を、能力の設定は [Agent Library](../skills/) と [環境変数](../worker-env/) を読んでください。
