---
title: セキュリティの強化
description: Ankole デプロイインスタンスを強化する end-to-end の形——最小権限、secret の規律、SSRF、credential のローテーション、最小限のネットワーク入り口。
section: Guides
order: 316
---

Ankole はセキュリティ境界を備えた状態で出荷されます。Principal/AuthZ、暗号化された secret、sandbox 化された worker、認証付きの入り口です。強化とは壁を足すことではなく、実際の利用に必要な最小の表面まで既存の壁を締めることです。このページは、オペレーターが強化する 5 つの面を、最初に最もリスクを閉じる順で説明します。

決定的な性質を先に述べます。Ankole のモデルは*既定で最小権限、証拠が要求する場合にのみ拡大*です。以下のすべての手順は、権限、secret の到達範囲、またはネットワーク経路を狭めます。何かを広げようとしていることに気づいたら、なぜかを問うてください——精査に値するのは広げる方の手であり、狭める方ではありません。

## 面 1:Principal と AuthZ の権限

Agent は自分の Principal の下で実行され、その Principal にできることは AuthZ によって囲われています。強化の手は*Agent ごとの最小権限*であり、1 つの強力な Agent ではありません。

- **Agent ごとに 1 つの Principal、Agent ごとに 1 つの目的。** customer-success の Agent とコーディングの Agent は別の Principal にすべきです。そうすれば、一方の侵害は両方の侵害にはなりません。
- **仕事を成す最小限を付与する。** channel を読む付与は、すべての channel に書く付与より狭い範囲です。特定の resource pattern にスコープされた付与は、ワイルドカードより狭い範囲です。[Principal and AuthZ](../principal-authz/) を参照してください。
- **directory のグループを同期し、グループに付与する。** 同期された AuthZ グループを使えば、チームメンバーシップで権限をスコープでき、誰かが離脱したときは、付与を 1 つずつ編集するのではなく、ソース directory のグループメンバーシップを外すことで権限を失効させられます。
- **迷ったら削除ではなく無効化。** 無効化された Principal は、インスタンス全体で即座に権限を失います。再び有効にできます。削除された Principal の uid は失われます。

監査面は `/permission-grants` と `/principals/:uid/grants` です。定期的に読みましょう。作成時に妥当だった付与が、過大なものに漂流することがあります。

## 面 2:Agent が使う credential

Agent の tool 用の credential は、Console の **Environment variables** に、secret ストレージを有効にして保存してください。各値を使用できる人を制限し、定期的にローテーションします。

- **値を控えめに表示する。** credential をローテーションするには置換値を入力します。確認のためだけに古い値を表示しないでください。[Environment variables](../worker-env/) を参照してください。
- **可能なら secret を Agent ごとにスコープする。** グローバルな secret はすべての Agent に届きます。Agent 単位の secret は 1 つに届きます。secret が本当に共有されていない限り、Agent 単位の形式を優先してください。
- **予約された名前を上書きしない。** `PATH`、`HOME`、`WORKER_ID`、`DATABASE_URL`、`ANKOLE_` で始まる名前、および一部の sandbox 名は Console で設定できません。この制限を迂回しないでください。
- **bootstrap secret を定期的にローテーションする。** `ANKOLE_SECRET_BASE` と `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` は他のキーを導出します。これらをローテーションするにはデプロイの再起動が必要であり、`ANKOLE_SECRET_BASE` が侵害された場合の爆発半径はインスタンス全体です。

## 面 3:SSRF と model 制御の fetch

`web_fetch` を持つ Agent は、Ankole に URL の fetch を依頼できます。`security.ssrf_filter` は、何を拒否するかを決める AppConfigure キーです。

- **既定値は `false`——そして、切り替える前にその理由を読んでください。** Ankole は一般に企業内の Agent として使われ、イントラネットへのアクセスが期待されます。フィルタはオフなので、内部への fetch が機能します。
- **クラウドのメタデータエンドポイントは常にブロックされます**。設定に関係なくです。`169.254.169.254` を読もうとする model は、フィルタのオンオフを問わず拒否されます。
- **フィルタがオンの場合**、プライベート、ループバック、リンクローカル、CGNAT のターゲットが拒否されます。Agent がパブリックインターネットから fetch し、内部 IP に到達する正当な理由がない場合にオンにしてください——それがこのフィルタの存在理由です。

この決定はデプロイインスタンス全体に適用され、間違った選択は「オフ」でも「オン」でもなく、Agent が実際に到達する必要がある範囲と一致しない選択です。

## 面 4:adapter の credential ローテーション

各チャット adapter と identity provider は credential（`appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID の `appPassword`、Google Workspace の `serviceAccountKey`）を保持します。定期的に、また漏えいが疑われる場合はいつでもローテーションしてください。

- **まず provider でローテーションし、次に Ankole で。** provider のコンソールで古い credential を無効化し、その後 adapter の AppConfigure に新しい値を入れます。順序が重要です。Ankole だけでローテーションし、provider 側でまだ有効な credential を残すのは、窓を残すことです。
- **正しい Console ページを使う。** Agent の tool 用の credential は **Environment variables** に入れます。chat channel と identity provider の credential は、それぞれの Console ページでローテーションします。
- **directory 同期の credential も credential です。** Google Workspace の `serviceAccountKey` と `adminEmail`、Graph に使う Entra ID アプリ——これらは directory を読めます。チャットの credential と同じ真剣さでローテーションを扱ってください。

## 面 5:最小限のネットワーク入り口

Ankole にはある程度の入り口が必要です。すべてが必要になることはまれです。各トランスポートが実際に要求するものまで締めましょう。

- **長接続の adapter は出方向だけで十分です。** Lark、Slack、DingTalk は出方向の WebSocket/Stream 接続を開きます。公開の入り口エンドポイントは必要ありません。これらだけを使うなら、デプロイをプライベートに保ってください。
- **Teams と webhook の入り口には公開エンドポイントが必要——スコープを限定してください。** Bot Framework と `/webhooks/v1/...` の玄関が到達可能である必要があります。入り口を使って、そのパスを想定される provider に制限し（可能なら送信元 IP で）、残りは adapter 自身の認証（Bot Framework JWT、Graph の `clientState`、ZAP/PLAIN の worker 認証）に頼ります。
- **webhook 委譲 URL は credential です。** Agent が検知を外部システムに委譲する場合、`/webhooks/v1/event-callbacks/*` が到達可能である必要があります。入り口、proxy、CDN、アプリケーションログで完全なパスを秘匿してください。この URL が許可するのは wake-up だけなので、Agent は結果に影響するアクションの前に、外部の現在の状態を検証しなければなりません。
- **Console 自体**は、管理ネットワークまたは VPN の背後に置き、パブリックインターネットに晒さないでください。bearer ゲートが不正アクセスを防ぎますが、管理者面を世界に晒す理由はありません。

## 監査の姿勢

強化は一度きりの作業ではありません。姿勢です。3 つの習慣がそれを維持します。

- **付与を定期的に読む。** `/permission-grants` と `/principals/:uid/grants` は、各 Principal が何をできるかを示します。漂流は起こります。
- **Brain の監査記録を読む。** `GET /brain/audit-log` は、Agent が何を信じるよう指示されたか、誰がそれを変えたかを示します。memory は、それに基づいて行動する Agent にとってセキュリティ面です。
- **復元をテストする。** [backup-and-restore](../backup-and-restore/) の規律はセキュリティコントロールです——復元できないバックアップは、侵害からの復旧ではありません。

## このガイドではないもの

これはペネトレーションテストでも、コンプライアンスチェックリストでもありません——Ankole の既存の境界を締めるオペレーターの手です。「すべてをロックダウンする」ことでもありません。最小権限とは、利用に必要な*最小*の面であり、ゼロの面ではありません。仕事ができない Agent は、それ自体が失敗です。そして、面ごとのページの代わりでもありません。上の各面は、正確なフィールドを説明する参照ページにリンクされています。

## 次のステップ

- 権限モデルについては、[Principal and AuthZ](../principal-authz/) を読んでください。
- Agent が使う credential については、[Environment variables](../worker-env/) を読んでください。
- SSRF キーと bootstrap secret については、[Environment variables](../environment-variables/) を読んでください。