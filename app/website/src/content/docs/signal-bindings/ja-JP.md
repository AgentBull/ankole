---
title: シグナルルーティングルール
description: チャットアプリを Agent に接続し、グループメッセージと memory の処理方法を選択します。
section: User guide
order: 14
---

シグナルルーティングルールは、どの Agent がメッセージを受け取るかを決定します。現在は、1 つのルールが 1 つのチャットアプリを 1 つの Agent に直接接続します。Agent は複数のルールを使って複数のチャットアプリに接続できます。

「signal」という言葉には、チャット以外への余地が含まれます。将来のルールでは、ルーティング式を使って channel、会話、その他の条件で Agent を選択できます。また、Salesforce などの system からのイベントを配信することもできます。

Slack、Microsoft Teams、Lark、Feishu、DingTalk のアプリをまだ準備していない場合は、先に [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) の channel provider の手順を完了してください。

## ルーティングルールを作成する

1. Console で **Signal Routing** を開き、**New routing rule** を選択します。
2. メッセージを受け取る Agent と Channel Provider アダプターを選択します。
3. `support-slack` のような分かりやすいルール名を入力します。
4. グループメッセージモードと memory スコープを選択します。
5. チャットアプリの credential と接続情報を入力し、ルールを保存します。
6. そのチャットアプリで bot にメッセージを送信し、選択した Agent が返信することを確認します。

各 bot アカウントに、それぞれ独自のチャットアプリとルーティングルールを割り当ててください。複数の Agent が異なる bot アカウントを使う必要がある場合は、各 bot に別々のアプリを作成し、ルールを 1 つずつ作成します。

こうすることで Agent の identity とメッセージを分離し、credential を個別にローテーションできます。

## グループメッセージモードを選択する

Console には、選択した Channel Provider がサポートするモードだけが表示されます。

| モード | Agent を宛てていないグループメッセージに何が起こるか |
|---|---|
| **Addressed messages only** | Agent はメッセージを見ず、返信もしません。 |
| **Observe unaddressed messages** | メッセージは会話 context に入りますが、Agent は起動しません。誰かが Agent を宛てた後、Agent はそれを context として使えます。 |
| **May intervene** | Agent はまず、会話に参加することが役立つかを判断します。発言すると判断した場合にのみ返信します。 |

Slack、Microsoft Teams、Lark、Feishu は 3 つのモードすべてをサポートします。DingTalk と WeCom は、bot を明示的に宛てたグループメッセージしか受信できないため、Console はこれらに最初のモードしか提供しません。WeCom にはこれ以外にも多くの制限があります（recall 不可、グループ内ファイル不可、Agent が会話を開始不可）。そのため、最初の channel としては推奨しません。[Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) の WeCom タブを参照してください。

**May intervene** は、Agent があらゆるメッセージに返信することを意味しません。いつ発言するかを Agent に判断させ、各メッセージは一度だけ判断されます。あるグループでいつ発言すべきかを Agent に伝えるには、そのグループ内で channel 常駐指示を直接与えます（例: 「CI が赤になった時だけ発言して」）。それでも発言しすぎる場合は、まず常駐指示または役割指示を厳しくします。判断の挙動と常駐指示については [アンビエント介入](../ambient-intervention/) を参照してください。

質疑応答のみが必要なグループでは、**Addressed messages only** を使用します。

## memory スコープを選択する

**Shared** は、グループメッセージがこのインスタンスの共有 memory スコープに入るようにします。Agent が会話をまたいで知識を保持する必要がある作業グループに使います。

**Channel only** は、グループメッセージをこの channel だけが読み取れる memory に保持します。顧客データ、機密プロジェクト、分離が必要なチームに使います。

## ルールの再構成または削除

対象 Agent、グループメッセージモード、memory スコープ、チャット credential を変更できます。別の Agent を選択すると、新しいメッセージはその Agent に送られます。既存の会話と memory は自動的に移動しません。

ルールを削除すると新しいメッセージの配信は停止しますが、チャットアプリは削除されません。後で同じアプリで新しいルールを作成できます。

## Agent が返信しない場合

- **Channel Provider がない場合:** **Agent Library → Control Plane Plugins** を開き、その plugin を有効にして、ページが指示したら control plane を再起動します。
- **bot がグループメッセージを受信しない場合:** provider のイベント購読、権限、アプリのリリース状態を確認します。DingTalk と WeCom のグループメッセージは、bot への明示的な @ メンションが必要です。
- **WeCom が予期しない動作をする場合:** 最初に [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) の WeCom タブと動作を比較してください。よくある原因は、スーパー管理者が作成していない bot、信頼済み IP の未設定、ユーザーがまだアクティブ化していない会話です。
- **ルールは保存されたが返信がない場合:** 対象 Agent が有効であること、model 設定が動作すること、ルールがルール一覧に存在することを確認します。
- **ダイレクトメッセージは動くがグループメッセージは動かない場合:** グループメッセージモードを確認し、bot が対象グループに属していることを確認します。

provider 固有の権限、イベント、credential は [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) を使用します。

DingTalk ルールでストリーミングカードの返信を使うには、DingTalk カードプラットフォームに AI カードテンプレートが 1 つ必要です。[Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule) の DingTalk タブの詳細セクションで、その構築方法を示しています。
