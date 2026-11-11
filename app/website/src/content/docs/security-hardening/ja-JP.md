---
title: セキュリティの強化
description: Ankole デプロイインスタンスのセキュリティ強化ガイド — 最小権限、シークレット管理、SSRF 対策、認証情報ローテーション、ネットワーク入口の最小化について解説します。
section: Guides
order: 316
---

Ankole には、Principal / AuthZ による権限制御、暗号化されたシークレット管理、Agent ごとに独立した Worker コンテナ、認証付きの通信エンドポイントなど、基本的なセキュリティ境界があらかじめ組み込まれています。セキュリティ強化（ハードニング）の目的は、新たな防御層を闇雲に付け足すことではなく、実際の業務に必要な最小限の範囲までこれらの境界を引き締めることにあります。このページでは、オペレーターが見直すべき 6 つの領域を、リスク低減効果の高い順に説明します。

Ankole のセキュリティ設計を貫く基本原則は、**「デフォルトで最小権限とし、明確な根拠がある場合にのみ広げる」**という考え方です。以下で紹介する手順はすべて、権限範囲、シークレットの到達範囲、またはネットワーク経路を絞り込むものです。もし設定を緩める方向へ変更しようとしているなら、本当にその拡大が必要なのかを立ち止まって確認してください。慎重な精査が求められるのは、制限を狭めるときではなく広げるときです。

## 面 1:Principal と AuthZ の権限

すべての Agent は固有の Principal のもとで動作し、実行できる操作は AuthZ によって厳密に制限されます。セキュリティ強化の基本は、1 つの万能な Agent に強い権限を集約するのではなく、**Agent ごとに最小権限を割り当てる**ことです。

- **1 Agent につき 1 Principal、1 つの明確な役割にする。** カスタマーサクセス担当の Agent とコード開発担当の Agent には別々の Principal を割り当ててください。そうしておけば、万が一片方が侵害されても、もう片方の権限まで奪われる事態を防げます。
- **業務遂行に必要な最小限の grant だけを付与する。** 全チャネルへの書き込み権限よりも特定チャネルの読み取り権限の方が安全であり、ワイルドカードよりも特定のリソースパターンに絞った grant の方が影響範囲を抑えられます。詳しくは [Principal and AuthZ](../principal-authz/) を参照してください。
- **ディレクトリのグループを同期し、グループ単位で権限を付与する。** 企業ディレクトリと同期された AuthZ グループに対して grant を設定しておけば、チーム単位で権限を管理でき、メンバーの異動や退職時にも個別の grant を探して編集することなく、元ディレクトリの所属変更だけで自動的に権限を失効させられます。
- **一時停止（Suspend）とオフボーディング（Offboard）を明確に使い分ける。** Human Principal には物理削除アクションがありません。**一時停止（`disposition: :suspended`）** はセッションとトークンを即座に失効させ、以降の実行を停止しつつ、復帰時に権限を戻せるよう個人用の `SiteCredential` を保持します。**オフボーディング（`disposition: :offboarded`）** はセッションとトークンを失効させ、以降の実行を停止したうえで、他と共有されていない `SiteCredential` や Pod のメール紐付けも解放します。メンバーが組織を離れる際は必ずオフボーディングを選択してください。

権限の監査には `/api/v2/permission-grants` と `/api/v2/principals/:uid/grants` エンドポイントを利用できます。定期的に棚卸しを行いましょう。設定当初は妥当だった grant も、運用の変化に伴って過剰な権限（権限ドリフト）になっていることがあります。

## 面 2:Agent が使う credential

GitHub、Lark/Feishu、Slack、Linear などの外部連携には、まず **Pod → Connections**（`Ankole.Connectors`）の利用を優先してください。上流の OAuth トークンやアプリ認証情報は control plane 内で暗号化保持されたまま Worker コンテナへは渡されず、control plane が MCP リクエストを中継したり、`GIT_ASKPASS` のような turn 限定の一時ヘルパーを注入したりします。Worker 内のカスタム CLI やスクリプトで直接必要になる API キーは Console の **Environment variables**（`WorkerEnv`）でシークレット保存を有効にして登録し、対象範囲を絞って定期的にローテーションしてください。

- **保存済みの値をむやみに再表示しない。** 認証情報をローテーションする際は、古い値を開いて確認するのではなく、新しい値をそのまま上書き入力してください。詳しくは [Environment variables](../worker-env/) を参照してください。
- **可能なかぎりシークレットを Agent 単位にスコープする。** グローバルスコープのシークレットは全 Agent に渡されますが、Agent 単位のシークレットは対象の 1 体だけに渡されます。複数の Agent で本当に共有する必要がある場合を除き、Agent 単位での設定を優先してください。
- **予約済みの環境変数名を上書きしない。** `PATH`、`HOME`、`WORKER_ID`、`DATABASE_URL`、`ANKOLE_` で始まる変数名、および [Environment variables](../worker-env/) に記載されている予約名は Console から設定できません。この保護制限を迂回しようとしないでください。
- **暗号化の起点となるシークレットを保管する。** `ANKOLE_SECRET_BASE` は、その値で暗号化したデータと一緒にバックアップしてください。値を変えて再起動しても保存済みシークレットは再暗号化されないため、元の値を使うか、別途データを移行する必要があります。`ANKOLE_FUNCTION_RUNTIME_TOKEN` をローテーションするときは、コントロールプレーンと `ankole-function-runtime` の両方を更新し、両サービスを再起動します。なお、Worker 接続用の認証情報はブートストラップシークレットではなく、オペレーターが手動設定するものでもありません。コントロールプレーンが Worker の世代（generation）ごとにランダムな認証情報を自動生成し、認証照合には保存したダイジェスト値を使い、同一世代の再起動に必要な値は暗号化して保持します。

リモート Skill MCP サーバー（`streamable_http`）の bearer token は、宣言した `bearer_token_env_var` の名前で **Environment variables** に登録します。制御プレーンがプロキシ要求に使い、Worker のスナップショットからは除外します。

## 面 3:SSRF と model 制御の fetch

`web_fetch` 機能を持つ Agent は、指定した URL の取得を Ankole に要求できます。どの宛先を拒否するかは AppConfigure の `security.ssrf_filter` キーで制御します。

- **既定値は `false` です（変更する前に背景を確認してください）。** Ankole は社内ネットワーク上の業務システムと連携する用途で広く使われており、イントラネットへのアクセスが前提となるケースが多いため、標準では内部向けフェッチが通るようフィルタがオフになっています。
- **クラウドのメタデータエンドポイントは設定にかかわらず常時ブロックされます。** `security.ssrf_filter` のオン・オフを問わず、モデルが `169.254.169.254` などを読み取ろうとしても必ず拒否されます。
- **フィルタを `true` にすると、プライベート IP、ループバック、リンクローカル、CGNAT アドレスへの接続がすべて拒否されます。** Agent がパブリックインターネット上の情報だけを取得すればよく、社内 IP へアクセスする必要がない環境では、このフィルタをオンにしてください。

この設定はデプロイインスタンス全体に適用されます。「オンとオフのどちらが正解か」は一概には決まらず、Agent が業務上本当にアクセスすべきネットワーク範囲と合致しているかどうかが判断基準になります。

## 面 4:adapter の credential ローテーション

各チャットアダプターや Identity Provider は、連携用の認証情報（`appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID の `appPassword`、Google Workspace の `serviceAccountKey` など）を保持しています。定期的なローテーションに加え、漏えいの疑いがある場合はただちに更新してください。

- **先に外部 Provider 側でローテーションし、続けて Ankole 側を更新する。** 外部 Provider の管理コンソールで新しい認証情報を発行して古いものを失効させ、その直後に Ankole 側の設定を更新してください。順番を逆にして、Ankole 側だけ書き換えたまま Provider 側で古い認証情報を有効なまま残すと、悪用可能な隙を残すことになります。
- **チャットチャネル、Identity Provider、コネクターの認証情報を WorkerEnv に入れない。** 再利用可能な外部サービス連携は **Pod → Connections** で管理し、チャットチャネルや Identity Provider の認証情報はそれぞれの専用 Console ページで管理・ローテーションします。リモート Skill MCP の bearer token は、前述の環境変数の手順に従って登録してください。
- **ディレクトリ同期用の認証情報も同じ重要度で扱う。** Google Workspace の `serviceAccountKey` と `adminEmail` や、Microsoft Graph 連携用の Entra ID アプリ認証情報は、組織ディレクトリ全体を読み取れる強い権限を持っています。チャットボットのトークンと同等以上に厳重にローテーションを管理してください。

## 面 5:最小限のネットワーク入り口

Ankole の運用にはいくつかの通信経路が必要ですが、すべての入口を外部公開しなければならないケースは稀です。利用するトランスポートが実際に必要とする範囲だけに公開面を絞り込みましょう。

- **常時接続型のアダプターなら外向き通信だけで完結する。** Lark、Slack、DingTalk は Ankole 側から外向きの WebSocket / Stream 接続を張るため、外部から到達可能な受信エンドポイントを公開する必要はありません。これらのチャネルだけを使う場合は、インスタンスをプライベートネットワーク内に閉じたまま運用してください。
- **Teams や Webhook を使う場合は公開エンドポイントのスコープを絞る。** Bot Framework や `/webhooks/v1/...` の受信パスには外部から到達できる必要があります。リバースプロキシや Ingress 側で公開パスを対象エンドポイントのみに限定し（可能であれば送信元 IP も制限し）、ペイロードの正当性は各アダプター自身の認証機構（Bot Framework JWT や Graph の `clientState` など）で検証させます。
- **Webhook 委譲 URL は認証情報と同等に秘匿する。** Agent が外部システムのイベント検知を待ち受ける場合、`/webhooks/v1/event-callbacks/*` への到達性が必要になります。Ingress、プロキシ、CDN、アプリケーションログに URL のフルパスが残らないようマスクしてください。なお、この URL が許可するのは wake-up トリガーの投入だけなので、重要な操作を実行する前には必ず Agent 側で外部システムの現在状態を再確認させる必要があります。
- **管理 Console 自体はインターネットに直接公開しない。** 管理ネットワーク内や VPN の背後に配置してください。ブラウザーセッションによる認証で未認証アクセスはブロックされますが、管理画面そのものをパブリックインターネットへ露出させる理由はどこにもありません。

## 面 6:Worker コンテナ、Function Runtime、コントロールプレーン

各 Agent には専用の Worker コンテナ（または Pod）が 1 つずつ割り当てられ、異なる Agent 間で Worker、キャッシュディスク、認証情報を共有することはありません。一方、ステートレスな TypeScript プログラム（Workflow オーケストレーター、PTC、Pod Applet バックエンド、Automation Job を含む公開済み Applet Action、およびホスト MCP 呼び出し）は独立した `ankole-function-runtime` サービス上で実行され、データベース認証情報も Kubernetes の ServiceAccount トークンも持ちません。各 Worker コンテナ・Pod 内では、`root` スーパーバイザー（`ankole-worker-supervisor` と FUSE ヘルパー `ankole-rclone`）がプライベートな mount / PID 名前空間内に限って `/dev/fuse` と `SYS_ADMIN` を保持して `/drive` をマウントし、Agent の子プロセスを起動する前にすべての Linux ケーパビリティを破棄します。Worker 内のシェルコマンド、Codex `app-server`、Chromium はすべて空のケーパビリティセットかつ `sudo` 権限なしの `uid 1000`（`gid 1000`）で実行されます。

- **コマンドはケーパビリティおよび `sudo` なしの `uid 1000` で動作する。** `/workspace` 配下にユーザーレベルのパッケージを追加したり、許可された `/drive` マウントを読み書きしたりすることはできますが、FUSE マウントの変更や OS のシステムパッケージ導入はできません。なお、同一 Agent 内の複数 Session は同じファイルシステムとプロセス空間を共有します。
- **Worker の認証情報は単一の Agent 世代だけに紐づく。** Worker スーパーバイザーは RuntimeFabric および Drive VFS 用の認証情報をメモリ上にのみ保持し、子コマンドの環境変数からは除外します。別の Agent の認証情報や、すでに入れ替えられた旧世代 Worker の認証情報では接続できません。
- **コントロールプレーンをホスト root 相当の重要コンポーネントとして保護する。** コントロールプレーンは Docker ソケット、または Pod・Secret・PVC を作成・削除できる Kubernetes Namespace Role を通じて Worker を管理します。特に Docker ソケットへのアクセス権は、ホスト OS の root 権限と同等である点に留意してください。
- **Kubernetes 環境では gVisor を併用する。** Kubernetes `WorkerProvider` YAML の `podTemplate.spec.runtimeClassName` に、クラスターの gVisor RuntimeClass（例：`gvisor`）を指定します。設定を変更すると、そのプロバイダー配下の Worker はアイドル時に順次新しい構成へ入れ替わります。Helm の `worker.runtimeClassName` は初回起動時に自動生成される Provider の初期値として使われるため、インポート完了後は Console 側から Provider 設定を編集してください。
- **Worker と `ankole-function-runtime` の通信可能範囲を制限する。** Docker Compose 環境では、Worker コンテナは `ankole_workers` ブリッジに、`ankole-function-runtime` は `ankole_functions` ブリッジに接続され、どちらもコントロールプレーンとインターネットへは通信できますが、内部の `ankole_backend` ネットワーク上にある PostgreSQL へは到達できません。クラウド VM 上で動かす場合は、インスタンスメタデータの hop limit を `1` に設定するか、コンテナから `169.254.169.254` への経路を遮断してください。Helm 環境では、`networkPolicy.enabled` を有効にすることで Worker Pod へのインバウンド接続がすべて遮断され、アウトバウンドもコントロールプレーン、DNS、および `networkPolicy.workerDeniedCIDRs` 以外のパブリックアドレスのみに制限されます。さらに専用の `NetworkPolicy` によって、`ankole-function-runtime` もコントロールプレーンからの受信と `functionRuntime.deniedCIDRs`（プライベート帯域およびメタデータ CIDR）を除くパブリック送信のみに制限されます。あわせて、クラスタノード側のインスタンスメタデータ hop limit も `1` に設定してください。

## 監査の姿勢

セキュリティ強化は一度設定して終わる作業ではなく、継続的な運用習慣そのものです。特に次の 2 点を定常運用に組み込んでください。

- **grant の棚卸しを定期的に行う。** `/api/v2/permission-grants` と `/api/v2/principals/:uid/grants` を確認し、各 Principal に付与されている現在の権限を点検してください。組織や運用の変化に伴う権限の肥大化は必ず起こります。
- **バックアップからのリストア手順を実際に訓練する。** [backup-and-restore](../backup-and-restore/) の運用は重要なセキュリティ対策の一部です。障害や侵害が発生したときに確実に復元できないバックアップは、復旧手段として機能しません。

## このガイドではないもの

このページはペネトレーションテストの手順書でも、規制コンプライアンスの網羅的なチェックリストでもありません。Ankole が備えるセキュリティ境界を実運用に合わせて適切に引き締めるための実践ガイドです。また、「あらゆる機能を無差別に塞ぐこと」を推奨するものでもありません。最小権限とは業務に必要な**最小限**の面を残すことであって、ゼロにすることではないからです。必要な業務すら遂行できない Agent になってしまっては本末転倒です。各設定項目の詳細な仕様については、それぞれのセクションからリンクされているリファレンスページを参照してください。

## 次のステップ

- 権限モデルの詳細については、[Principal and AuthZ](../principal-authz/) を参照してください。
- Agent が利用する認証情報の管理については、[Environment variables](../worker-env/) を参照してください。
- SSRF 設定キーとブートストラップシークレットについては、[Environment variables](../environment-variables/) を参照してください。
- 各 Agent のコマンドを実行する Worker の仕組みについては、[Agent Computer Worker](../agent-computer-worker/) を参照してください。
