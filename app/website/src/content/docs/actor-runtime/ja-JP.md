---
title: Actor Runtime
description: 長時間実行のセッションがどのように生き、目覚め、失敗し、復旧するか——actor key、OTP の失敗ドメイン、activation フェンス、RuntimeFabric のライブパス。
section: Developer guide
order: 103
---

Actor Runtime は、セッションをリクエストではなく長命のものにするものです。signal が到着し、セッションが目覚め、worker が 1 つの Turn を実行し、Turn がコミットされるか失敗し、セッションは待機に戻る——その間ずっと、プロセスがクラッシュしても PostgreSQL の永続的なトランスクリプトは正しいままです。このページは、そのライフサイクルを `Ankole.SignalsGateway.ActorRuntime` の実コードに対応付けて説明します。

中心的な設計選択を先に述べます。正しさはプロセスではなくデータベースにあります。生きているプロセスは、推論とスループットのための最適化です。遅れた、またはセッションをまたぐ応答が状態を汚染するのを防ぐフェンスは、行に対する単純な等価チェックです。すべてのプロセスを失っても、永続的なトランスクリプトは無傷です。

## actor key

長時間作業の単位は 1 つの actor key です。`{agent_uid, session_id}`。1 つの Agent は多くのセッションを持てます。1 つのセッションは正確に 1 つの Agent に属します。以下のすべて——シリアルコントローラー、activation、delivery 行、worker の割り当て——はこのペアをキーにします。

セッションは、context、workspace 状態、steering、キャンセル、復旧が出会う場所です。それはリクエストでもキュー job でもなく、数時間または数日にわたって目覚め、待ち、再開できるステートフルな作業 ID です。

## 2 つの層、2 つの保証

runtime は 2 つの層を意図的に分離します。必要とする保証が異なるからです。

- **AI-agent 状態**——会話、Turn、message——は*永続的な真実*です。AIGateway が所有するテーブルにあり、あらゆるクラッシュを生き延びます。
- **Actor-runtime プロジェクション**——activation、delivery、割り当て——はより安価な*runtime ヒント*です。進行中の作業にフェンスを張り、永続層から再構築できます。

この分離が、worker が交換可能である理由です。worker は Turn を実行します。その Turn の応答がまだ有効なものかを決めるのは、フェンス行です。クラッシュした、または置き換えられた worker からの遅れた応答は、フェンスに失敗して無害に破棄されます。

## シリアルコントローラー、actor ごとに 1 つ

各 actor key について、`SessionController` GenServer がダイナミックスーパーバイザーによってオンデマンドで spawn され、`ActorDirectory` の一意の名前で登録されます。1 つのコントローラーが 1 つの actor key のスケジューリングを直列化するため、通常のパスで 2 つの Turn が同じセッションを競合することはありません。

これは推論のための最適化であり、正しさの境界ではありません。コントローラーがクラッシュして再起動しても、actor の状態は失われません——本当の守りは、最初から永続データベースのフェンスでした。コントローラーの開始は冪等です。同じ actor に対する 2 つの並行 wakeup が開始を競い、負けた方は `{:already_started, pid}` を受け取り、両方の呼び出し側がそれを成功として扱い、生きている pid を返します。呼び出し側が誰が actor を開始するかを調整することは決してありません。

## OTP の失敗ドメイン

監督ツリーは、1 つの失敗が全員の失敗にならないように構築されています。

- **runtime スーパーバイザー**は `:one_for_one` で実行されます。その子——トランスポート、ネーミング、actor ごとのコントローラー——は独立した関心事です。1 つの子がクラッシュしても、他の子の状態は無効になりません。永続的な正しさは PostgreSQL にあり、これらのプロセスにはないからです。
- **session スーパーバイザー**は `DynamicSupervisor` で、こちらも `:one_for_one` です。各 `SessionController` はそれ自体が失敗ユニットです。1 つのコントローラーがクラッシュしても、1 つの actor が誤動作しても、他の actor のコントローラーに触れることなく分離され、再起動されます。

実際の効果は、1 つの Agent がハング、タイムアウト、クラッシュしても、デプロイ全体の障害になるのではなく、自分のブランチで分離または再起動されることです。actor は静的な子リストなしで、runtime に出入りします。

## activation フェンス

セッションが Turn を実行するために目覚めると、runtime は `ActorSessionActivation` を作成します。これは、その actor セッションのライブリースプロジェクションです。activation は、その actor key の単調カウンターである `actor_epoch`、`lease_id` と `lease_expires_at`、`current_actor_event_id`、そしてライブ Turn のインプレースな steering のたびに増える `revision` を運びます。

activation の状態は `starting → active → draining` と遷移し、`stopped` と `failed` が終端です。actor key ごとにライブ activation は同時に 1 つだけ存在でき、部分一意インデックスによって強制されます。リース失敗後の新しい activation はより高い epoch を取得し、その epoch が、以前の activation からの遅れた応答を単純な不等式で失敗させる安価なフェンスです。

すべての worker 応答は、フィールドがデータベース行に対して等価チェックされる `turn_ref` をエコーしなければなりません——activation、actor epoch、Turn を指名する delivery 行の三重フェンスです。これにより、遅れた、またはセッションをまたぐ worker 応答は、永続トランスクリプトを汚染する代わりに無害に失敗します。そして、これに memory 内のセッション状態は不要です。意図的に弱く置かれた唯一の箇所——runtime フェンスを再起動で失った永続的に開始された Turn——は、対象の message 行に対応する正確な runtime イベントハンドラーによって修復されます。

## delivery 行とライブパス

キューに入った actor event と worker の受理の間には、`ActorEventDelivery` 行があります。1 回の worker 実行は、正確に 1 つの `actor_event_id` を処理します。フェンス五つ組——`activation_uid`、`actor_epoch`、`actor_event_id_fence`、`revision`、そして actor key——は activation から各 delivery 行にコピーされるため、古い応答のチェックは memory 内のセッション状態を必要とせず、データベースに対する純粋な等価比較として実行されます。

delivery の状態は `created → sent → accepted` と遷移し、`send_failed` と `superseded` が終端で無視可能です。control plane から worker へのライブパスは RuntimeFabric——ZeroMQ ベースのライブトランスポート——上を走り、デコードされたトラフィックは socket を所有する broker の上層でルーティングされます。worker ライフサイクルイベントは直列化され、actor イベントはセッションごとのコントローラーに転送され、独立した worker RPC リクエストはタスクスーパーバイザーの下で実行されます。ドメインコールバックがトランスポート broker プロセスで実行されることはありません。

## リースの期限切れと復旧

activation は `now < lease_expires_at` の間だけ有効です。watchdog は期限切れの進行中 activation を失敗させ、その actor event が再試行できるようにします。通常は、現在のイベントが nil の温かい activation を停止します。Turn がエラーになると、イベントは再試行のために `open` のまま残り、worker の失敗が続いてオーバーフローしきい値を越えると `dead_letter` に移ります。再試行は指数バックオフを使い、5 から 120 秒の間に制限され、失敗した試行ごとに epoch が増えるため、その遅れた応答は後の再試行と一致できません。

復旧の話は 1 文で済みます。永続イベントは open のまま、runtime プロジェクションは再構築され、より高い epoch を持つ新しい activation がイベントを拾い直します。actor は自分の場所を失いません。なぜなら、その場所は最初からプロセスの中になかったからです。

## Actor Runtime ではないもの

永続的な事実を保存する場所ではありません——それらは AI-agent 状態レイヤーと PostgreSQL にあります。worker でもありません。worker は、Turn を実行する交換可能な Agent Computer Worker プロセスです。そして、入り口面でもありません。signal は [SignalsGateway](../signals-gateway/) を通じて到着し、actor event になると、目覚めさせて実行するのはこの runtime の仕事です。境界は、永続的なキューイベントをフェンス付きの回復可能なライブ Turn に変換し、永続的なコミットに戻すことです。

## 次のステップ

- signal が actor event になる仕組みは、[SignalsGateway](../signals-gateway/) ページを読んでください。
- 目覚めた後に worker が実行する model Turn は、[AIGateway API](../ai-gateway/) を読んでください。
- システム全体のビューは、[architecture overview](../architecture/) を読んでください。