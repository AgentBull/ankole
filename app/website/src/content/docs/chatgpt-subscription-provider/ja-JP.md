---
title: ChatGPT サブスクリプション Provider
description: デバイスログインと共有 credential pool で ChatGPT サブスクリプションを AIGateway に接続します。
section: User guide
order: 41
---

ChatGPT サブスクリプションは通常の AIGateway provider です。通常の会話や Background Agent Jobs を含め、任意の model profile がそれを指せます。profile は provider 行と model を選択します。行内の 1 つのアカウントは選択しません。

provider 行は credential pool を所有します。control plane は各アカウントの token を暗号化し、OAuth token を更新し、各リクエストに使用可能な pool メンバーを選択します。Agent Computer が受け取るのは、AIGateway のエンドポイントと AIGateway key だけです。ChatGPT の refresh token は決して受け取りません。

## Provider を作成する

1. **Console → LLM Providers** を開きます。
2. provider を追加し、provider の種類として **ChatGPT Subscription** を選択します。
3. `chatgpt-main` のような安定した provider ID を入力します。
4. provider を保存します。

デフォルトのエンドポイントと identity ヘッダーは Codex プロトコルに一致します。高度なエンドポイントやヘッダーは、デプロイに特定の要件がある場合にのみ変更してください。

## デバイスログインでアカウントを追加する

1. ChatGPT サブスクリプション provider を開きます。
2. **Add ChatGPT account** を選択します。
3. 検証リンクを開き、Console が表示するワンタイムコードを入力します。
4. Console がログインを完了し、pool メンバーを追加するのを待ちます。
5. 同じ provider にアカウントを追加するプロセスを繰り返します。

Console は、利用可能な場合は公式のデバイスログインを使用します。そのルートが利用できない場合、Console はブラウザのサインイン URL を表示し、完全なコールバック URL を貼り付けるよう求めます。Enterprise オペレーターは、代わりに信頼済み access token とその ChatGPT アカウント ID を追加できます。

## credential pool を構成する

各メンバーには、label、priority、source、ヘルス状態、リクエスト数、レート制限データ、model または画像使用量があります。secret token は決して表示されません。

1 つの選択戦略を選びます。Console は表示名を翻訳しますが、API 値と保存値は安定したままです。

| Console ラベル | API 値 | 動作 |
| --- | --- | --- |
| Fill first | `fill_first` | 利用できなくなるまで、最初のヘルシーメンバーを使用します。 |
| Round robin | `round_robin` | 選択のたびにローテーションします。 |
| Least used | `least_used` | リクエスト数が最小のメンバーを選択します。 |
| Random | `random` | 任意のヘルシーメンバーを選択します。 |

`exhausted` メンバーは、クールダウン後に自動的に戻ります。`dead` メンバーは、新しいログインまたは代替 credential が必要です。メンバーを無効化または削除することもできます。label だけを変更しても `dead` 状態はクリアされません。

## Provider を Agent に割り当てる

1. **Console → Agents** を開き、Agent を選択します。
2. 必要な model profile を開きます。永続 Job には **Background Agent Jobs** を、通常の model turn には別の profile を使います。
3. ChatGPT サブスクリプション provider と、利用資格のある model を選択します。
4. 必要に応じて reasoning effort と Fast Mode を設定します。
5. profile を保存します。

すべての呼び出しは引き続き AIGateway を通ります。ゲートウェイは可能な場合、同じアカウントに stateful thread を保持し、再試行可能な provider 障害時にローテーションし、別の provider にはフォールバックしません。すべてのメンバーが利用できない場合、対話型の呼び出しは、次の回復時刻付きのレート制限エラーを返します。Background Agent Job は、最も早い pool メンバーが回復するまで `queued` に戻ります。

Job の作成、制御、トラブルシューティングについては [Background Agent Jobs](../background-jobs/) を参照してください。
