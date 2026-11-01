---
title: Principal と AuthZ
description: Ankole デプロイメントインスタンスの権限境界 — 責任主体としての Principal、permission grant、グループメンバーシップ、およびプロンプト上の慣習に頼らないランタイム強制の仕組みを説明します。
section: Developer guide
order: 106
---

Ankole におけるあらゆる操作（人間のサインイン、Agent による Turn の実行、Job 完了時のオーナー起動など）は必ず Principal を主体として実行され、その Principal に何が許可されているかは操作の瞬間に AuthZ が判定します。このページでは、`Ankole.Principals` と `Ankole.AuthZ` の実装に沿って、この権限境界の仕組みを解説します。

最も重要な原則は、**認可はモデルに配慮を求めるプロンプト上の約束事ではなく、ランタイム境界で強制される決定論的な仕組みである**という点です。Principal は永続的な責任主体であり、付与された grant は PostgreSQL に保存されます。検査対象のすべてのアクションは明示的なスナップショットに対して Rust Kernel が評価し、呼び出し元はその判定結果に必ず従わなければなりません。

## Principal: 1 つの説明責任ある主体

Principal は、人間、Agent、システムサービスに共通する永続的な責任主体です。各 Principal は単一のテナントに所属し、グローバルに一意な不透明識別子 `uid` を持ちます。`principals` テーブルの各行は、`type`（`:human`、`:agent`、`:system`）、`status`（`:active` または `:disabled`）、さらに `:human` の場合は `:member` または `:guest` の `membership`（`:agent` と `:system` では `nil`）を保持します。

人間の Principal には、1 つの `HumanUser` 行、0 個以上のサイトスコープの `SiteCredential` 行（`principal_site_credentials`。検証済み Email OTP アドレスなど）、および 0 個以上のテナントスコープの `ExternalIdentity` 行（`principal_external_identities`。Identity Provider から連携された外部 ID）が紐付きます。Agent の Principal には 1 つの `Agent` 行が紐付きます。すべての主体を単一のテーブルに集約することで責任追跡の構造が一本化され、監査ログ、grant、グループメンバーシップのすべてが同じ不変の Principal `uid` を参照します。

人間の `membership` はテナント内の協業範囲を制御します。内部の `member` は computed group である `all_humans` に含まれますが、外部の `guest` は明示的な Pod ページ共有または Agent grant がなければアクセスできず、組み込み管理者グループ（`siteadmin` や `pod_admin`）への参加や Private ルートも持たず、Brain の `world` スコープも付与されません。

また、無効化された Principal に部分的な権限が残ることはありません。無効な主体に対しては Kernel が常に `principal_disabled` を返すため、Principal を無効化するだけで、個別の grant を一つずつ剥がさなくてもインスタンス全体で即座に権限が遮断されます。

## grant: 誰が何をできるか

`permission_grants` テーブルの各行は、次の 3 種類の受領者オーナーのうち厳密に 1 つだけを持ちます（`num_nonnulls(principal_uid, group_id, source_node_id) = 1` として、`Ankole.AuthZ.Validations.GrantShape` および PostgreSQL の CHECK 制約で強制されます）。

- Principal（`principal_uid`）
- Principal group（`group_id`）
- **Drive ノード Userset**（`source_node_id` と、`node_view`・`node_contribute`・`node_edit`・`node_manage`・`node_comment` のいずれかを取る厳密な `source_action` の組）

Drive ACL 向けの grant は、これに加えて `target_node_id` と `target_scope`（配下のサブツリーへ継承する `container`、または対象ノード単体の `self`）も保持します。すべての grant は次のフィールドで構成されます。

- `resource_pattern`：`Input.validate_resource_pattern_syntax` で検証されるコロン区切りの統一名前空間パターンです。対象には `site_console:**`（Site Console）、`tenant_console:**`（Pod 管理）、`agent:<uid>`（ランタイム Agent アクセス）、ならびに `drive:**`（`drive:space:**`、`drive:private:<uid>:**`、`drive:**:<node-id>:**`、`drive:**:<node-id>:node`）があります。なお、無制限の `"**"` 単体パターンは無効として拒否されます。
- `action`：コロンを含まない厳密な操作名文字列。
- `condition`：CEL の真偽値式。デフォルトは `"true"` で、`Input.validate_condition_syntax` によって構文検証されます。
- `description` および `metadata`：オペレーター向けの説明文とメタデータ。

Principal、グループ、Userset の各 grant は、それぞれの部分一意インデックスによって自然キー（`owner + resource_pattern + action + condition`）の一意性が保証されます。grant の作成、upsert、更新はすべてコントロールプレーン経由で行われ、不正なオーナー構造や構文エラーを含むルールはデータベース層でも拒否されます。

## Group: 静的および計算によるメンバーシップ

Principal group は名前付きの集合であり、Principal はグループを通じて間接的に grant を受け取れます。各グループは `domain`（`:operator`、`:directory`、`:im_group`、`:signal_source`）、`kind`（`:static` または `:computed`）、および computed group 用の CEL 式 `computed_condition` を持ちます。

すべてのテナントには、条件式 `principal.type == "human" && principal.membership == "member" && principal.status == "active"` を持つ組み込みの computed group `all_humans` と、その Pod 内の `tenant_console:**` 操作を付与する組み込みの static group `pod_admin` が存在します。特権サイトテナントにはさらに、組み込みの static group `siteadmin`（`site_console:**` および `tenant_console:**`）が存在します。`siteadmin` と `pod_admin` に所属できるのは、有効（`active`）な人間の内部メンバー（`member`）のみです。また、Site Console 上で表示対象のデータテナントを切り替えても、操作者自身の Identity や `siteadmin` の参照先が変わることはありません。静的メンバーシップは `principal_group_memberships` テーブルに保存され、計算メンバーシップは認可スナップショットに対して動的に評価されます。外部ディレクトリや IM チャネルのグループは、`principal_group_external_bindings` を介して同期されます。

## 決定がどのように行われるか

コントロールプレーンと Kernel は明確に役割を分担しており、この分離によって AuthZ を単なる助言ではなく確実な強制機構として機能させています。

- **コントロールプレーンは永続状態、Ash の認可、スナップショットの構築を担当します。** 保護対象のアクションは `Ankole.AuthZ.Extension` でルールを宣言し、`Ankole.AuthZ.Authorizer` が `%Ankole.AuthZ.Actor{principal, turn_authority, authn}` の実行主体を検査します。Agent ターンは Agent 自身のリソース権限を使います。検証済みの認証情報は `context.request.authn` に入り、Agent に適用される grant の CEL 条件を評価します。`turn_authority` と `WorkAccess` は指示が有効かを別途確認します。
- **Kernel と PostgreSQL は決定論的なルール評価を担います。** 通常の権限チェックでは、`Ankole.AuthZ.Snapshot` が単一の SQL 文で Principal、グループメンバーシップ、候補 grant を読み込み、Rust Kernel がリソースパターン、computed group、CEL 条件を評価します。Drive ノードについては、5 ビットの ACL アンカーグラフ（`node_view=1`、`node_contribute=2`、`node_edit=4`、`node_manage=8`、`node_comment=16`、ロールマスク `view=1`、`contribute=19`、`edit=23`、`manage=31`）を使い、リクエスト依存の CEL 条件を Rust Kernel で一度評価したうえで、直接 grant、グループ、コンテナ継承、Userset エッジを PostgreSQL の `WITH RECURSIVE`（`UNION` による最小不動点計算）で解決します。

`Ankole.AuthZ` の公開エントリポイントには、`authorize(subject, resource, action, context)`、真偽値を返す `allowed?/4`、単一アクションの判定マップを返す `authorize_decision/4`、単一リソースに対する複数アクションを一括評価する `authorize_all_decision/4`、同一スナップショット上で独立した複数のリソース・アクション組を評価する `authorize_checks/3`、および Drive コンテキスト評価用の `evaluate_drive_context/2` があります。いずれの関数も、呼び出し元の自己申告を無条件に信頼することはありません。

## 決定ステータス

認可判定は次の 4 つのステータスのいずれかを返し、呼び出し元はそれに応じた処理を行う義務があります。

- **`allow`**：アクションが許可されています。処理を続行します。
- **`deny`**：アクションが拒否され、`deniedAction` が返されます。呼び出し元はその操作を実行してはなりません。
- **`principal_disabled`**：対象の主体が無効化されています。明確な理由を伴う拒否として扱います。
- **`invalid_request`**：リクエスト自体の形式が不正です。漫然とリトライするのではなく、リクエスト内容を修正する必要があります。

判定のたびに診断イベントが出力されるため、拒否の発生理由は後から追跡可能です。また、`Ankole.AuthZ.Decision.result/1` を使えば判定マップを `:ok | {:error, reason}` 形式へ変換でき、呼び出し元のパターンマッチでそのまま分岐できます。

## 強制が実際に効く場所

ランタイムの主要な境界すべてで AuthZ が検査されるため、Agent が会話やプロンプトの工夫でこの制限を迂回することはできません。

- **AIGateway：** 検証済みトークンから呼び出しごとの subject を解決し、その subject の grant で利用可能なモデルセレクターと Provider を判定します。
- **ツールの準備とディスパッチ**では、実行する Agent が有効であること、ツールが宣言済みのカタログに含まれること、引数と指示が有効であることを確認します。ツールの所有モジュールは Agent の権限で対象リソースを検査します。
- **セッション Driver と Worker：** 実行セッションの Driver はコミット前に永続 fence を検証し、Worker からの Job 操作では永続 Job attempt fence と認証済み接続の Identity を検証します。
- **管理コンソール API：** Site Console（`/api/v2`）および Pod 管理（`/api/v2/pod/admin`）の操作には、検証済みのブラウザーセッション証明、CSRF 保護、および有効な `site_console:**` または `tenant_console:**` grant が必須です。

モデル自身が「自分には権限がある」と主張して認可を通すことは決してできません。各境界が Principal と grant を直接検査し、その結果を強制します。

## 運用者向けの表面

`/api/v2` 配下の Site Console JSON:API ルートが Principal、グループ、grant の管理機能（`site_console:**`）を公開しており、Pod 管理者は `/api/v2/pod/admin/*`（`tenant_console:**`）を通じてテナントのメンバー、招待、設定、Identity Provider を管理します。

`site_console:drive` 権限は、メンバーや Agent の Private コンテンツを含め、選択したテナントの Drive ツリー全体を対象とします。オペレーターは、この権限で付与されたアクションに応じて読み取り、更新、削除を行えます。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/principals` | Principal を一覧表示 |
| `POST` | `/api/v2/principals` | Human の内部メンバー Principal を事前作成 |
| `GET` | `/api/v2/principals/:uid` | 単一の Principal を取得 |
| `PATCH` | `/api/v2/principals/:uid` | Human Principal のプロフィール（`display_name`）を更新 |
| `PATCH` | `/api/v2/principals/:uid/membership` | Human Principal の `membership`（`member` または `guest`）を変更 |
| `GET` | `/api/v2/principals/:uid/access` | Human のアクセス状態、制限、復元レビュー用の投影を取得 |
| `POST` | `/api/v2/principals/:uid/access-disables` | Human Principal を一時停止（`suspended`）または退職処理（`offboarded`） |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 制限解除後に、無効化された Human Principal を復元 |
| `GET` | `/api/v2/principals/:uid/groups` | Principal の所属グループを一覧表示 |
| `GET` | `/api/v2/principals/:uid/grants` | Principal の grant を一覧表示 |
| `GET` | `/api/v2/principal-groups` | グループを一覧表示 |
| `POST` | `/api/v2/principal-groups` | オペレーター管理グループを作成 |
| `GET` | `/api/v2/principal-groups/:name` | 単一のグループを取得 |
| `PATCH` | `/api/v2/principal-groups/:name` | グループを更新 |
| `DELETE` | `/api/v2/principal-groups/:name` | オペレーター管理グループを削除 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | computed group の一致メンバーをプレビュー |
| `POST` | `/api/v2/permission-grants` | オペレーター管理の permission grant を作成（`/api/v2/permission-grants/:id` で `PATCH`/`DELETE`） |

grant とメンバーシップの更新操作はすべて `Ankole.AuthZ` を経由し、レコード書き込み前にオーナー構造、リソースパターン構文、CEL 条件構文が検証されます。さらに PostgreSQL の CHECK 制約と部分一意インデックスによって、ストレージ層でも同じ不変条件が保護されます。

## Principal と AuthZ がそうでないもの

AuthZ はプロンプトによるお願いでも、モデルの善意への期待でもありません。モデルに自制を求めるのではなく、Principal を検査してその結果をシステム側で強制します。また、Principal は単一インスタンスを別々の企業テナント境界へ切り分ける仕組みでもなければ、リクエスト単位の一時ロールでもありません。権限を付与し、グループ化し、評価するための不変の責任主体です。そして Rust Kernel も、オペレーターが個別にルールを書く第二のポリシーエンジンではなく、コントロールプレーンが組み立てたスナップショットを決定論的に評価する実行器として機能します。

## 次のステップ

- AIGateway のエッジで検証済みトークンがどのように Principal へ解決されるかについては、[AIGateway API](../ai-gateway/) を参照してください。
- Agent Principal の Driver fence がどのように Turn を保護するかについては、[Sessions](../sessions/) を参照してください。
