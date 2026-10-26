---
title: Principal と AuthZ
description: Ankole デプロイメントインスタンスの権限境界 — 説明責任のある主体としての Principal、権限 grant、グループメンバーシップ、プロンプトの慣習ではなくランタイムによる強制。
section: Developer guide
order: 106
---

Ankole のすべてのアクション（人のサインイン、agent による turn の実行、job による owner の wake）は Principal が実行し、その Principal が何をできるかはアクションの時点で AuthZ が決定します。このページでは、その境界を `Ankole.Principals` と `Ankole.AuthZ` の実際のコードに照らして説明します。

最初に決定的な性質を述べます。認可はランタイムの事実であり、境界で強制されるものであって、モデルに求める慣習ではありません。Principal は永続的で説明責任のある主体であり、その grant は PostgreSQL に保存され、チェックされるすべてのアクションは kernel が明示的な snapshot に対して評価し、呼び出し元はその決定に従わなければなりません。

## Principal: 1 つの説明責任ある主体

Principal は、人、Agent、システムサービス共通の永続的な責任主体です。各 Principal は 1 つのテナントだけに属し、グローバルに一意の不透明な `uid` を持ちます。`principals` 行の `type` は `:human`、`:agent`、`:system`、`status` は `:active` または `:disabled`、さらに `:human` に対しては `:member` または `:guest` の `membership`（`:agent` と `:system` は `nil`）を持ちます。

人の Principal は 1 つの `HumanUser` 行、0 個以上のサイトスコープの `SiteCredential` 行（`principal_site_credentials`。検証済み Email OTP アドレスなど）、および 0 個以上のテナントスコープの `ExternalIdentity` 行（`principal_external_identities`。Identity Provider から連携された identity）を持ちます。agent の Principal は 1 つの `Agent` 行を持ちます。すべての主体を 1 つのテーブルに集約することで、説明責任の形状が 1 つに統一され、すべての audit 行、grant、グループメンバーシップが同じ安定した Principal `uid` を指します。

人の `membership` はテナント内の協業境界を制御します。内部の `member` は計算グループの `all_humans` に含まれますが、外部の `guest` は明示的な Pod ページ共有または Agent grant を必要とし、組み込み管理者グループ（`siteadmin` や `pod_admin`）への参加や Private space の利用はできず、Brain の `world` スコープも付与されません。

無効化された Principal は部分的に使えるわけではありません。kernel の決定は無効な主体に対して `principal_disabled` を返すため、Principal を無効化すると、すべての grant を追いかけることなく、インスタンス全体でその権限が除去されます。

## grant: 誰が何をできるか

`permission_grants` の各行は、次の 3 種類の受領者オーナーのうち正確に 1 つだけを持ちます（`num_nonnulls(principal_uid, group_id, source_page_id) = 1`。`Ankole.AuthZ.Validations.GrantShape` と PostgreSQL の check constraint で強制されます）。

- Principal（`principal_uid`）
- Principal group（`group_id`）
- **Pod ページ Userset**（`source_page_id` と、`page_view`、`page_write_records`、`page_edit`、`page_manage` のいずれかの厳密な `source_action` の組）

Pod ACL の grant は `target_page_id` と `target_scope`（サブツリーへ継承する `container`、または対象ページのみの `self`）も保持します。すべての grant は次の要素を持ちます。

- `resource_pattern` — `Input.validate_resource_pattern_syntax` で検証され、コロン区切りの統一された名前空間を対象とします: `site_console:**`（Site Console）、`tenant_console:**`（Pod 管理）、`agent:<uid>` と `agent:<uid>:tool:<fn>`（ランタイム Agent とツール呼び出し）、および `pod:**`（`pod:space:**`、`pod:private:<uid>:**`、`pod:**:<page-id>:**`、`pod:**:<page-id>:page`）。単体の `"**"` パターンは無効です。
- `action` — コロンを含まない厳密な文字列。
- `condition` — CEL ブール式。デフォルトは `"true"` で、`Input.validate_condition_syntax` で検証されます。
- 運用者が読むための `description` と `metadata`。

Principal、グループ、Userset の各 grant は、それぞれの部分一意インデックスによって自然キー（`owner + resource_pattern + action + condition`）の一意性が保証されます。grant の作成、upsert、更新はすべて control plane の操作であり、不正な owner shape や構文違反のルールはデータベースで拒否されます。

## Group: 静的および計算によるメンバーシップ

Principal group は名前付きの集合で、Principal はこれを介して grant を受けることができます。group は `domain`（`:operator`、`:directory`、`:im_group`、`:signal_source`）、`kind`（`:static` または `:computed`）、および computed group 用の CEL `computed_condition` を持ちます。

すべてのテナントは、計算条件 `principal.type == "human" && principal.membership == "member" && principal.status == "active"` を持つ組み込みの computed group `all_humans` と、その Pod 内の `tenant_console:**` 操作を付与する組み込みの static group `pod_admin` を持ちます。特権サイトテナントにはさらに、組み込みの static group `siteadmin`（`site_console:**` と `tenant_console:**`）があります。`siteadmin` および `pod_admin` に参加できるのは、有効な human の `member` Principal のみです。Site Console で別のデータテナントを選択しても、操作者の identity や `siteadmin` の参照先は変わりません。静的メンバーシップは `principal_group_memberships` に保存され、計算メンバーシップは認可 snapshot に対して評価されます。外部ディレクトリや IM チャネルのグループは `principal_group_external_bindings` を通じて同期されます。

## 決定がどのように行われるか

control plane と kernel は意図的に作業を分割しており、この分割こそが AuthZ が助言ではなく強制可能である理由です。

- **control plane は永続状態、Ash 認可の強制、snapshot の組み立てを所有します。** 保護された Ash アクションは `Ankole.AuthZ.Extension` でルールを宣言し、実行時には `Ankole.AuthZ.Authorizer` が `%Ankole.AuthZ.Actor{principal, interactive_principal, turn_authority, authn, interactive_authn}` を使って強制します。検証済みのブラウザ、OIDC、Worker の認証事実は `context.request.authn` に格納され、CEL 条件から参照できます。`interactive_principal` が存在する場合（人間が起動した Agent ターンなど）は、Agent と人間の両方が検査を通過する必要があります（`Human ∩ Agent`）。
- **kernel と PostgreSQL は決定論的なルール評価を担います。** 通常のチェックでは、`Ankole.AuthZ.Snapshot` が 1 つの SQL 文で Principal、グループメンバーシップ、候補 grant を読み込み、Rust kernel がリソースパターン、computed group、CEL 条件を評価します。Pod ページについては、4 ビットの ACL アンカーグラフ（`page_view=1`、`page_write_records=2`、`page_edit=4`、`page_manage=8`、ロールマスク `view=1`、`contribute=3`、`edit=7`、`manage=15`）がリクエスト依存の CEL 条件を Rust kernel で一度評価し、直接 grant、グループ、コンテナ継承、Userset エッジを PostgreSQL の `WITH RECURSIVE`（`UNION` 最小不動点）で解決します。

`Ankole.AuthZ` の公開エントリポイントは、`authorize(subject, resource, action, context)`、ブール値を返す `allowed?/4`、単一アクションの決定マップを返す `authorize_decision/4`、1 つのリソースに対する複数アクションを一括評価する `authorize_all_decision/4`、1 つの snapshot 上で独立したリソース／アクション組を評価する `authorize_checks/3`、および Pod コンテキスト評価用の `evaluate_pod_context/2` です。いずれも呼び出し元の自己申告を信頼しません。

## 決定ステータス

決定は 4 つのステータスのいずれかで返り、それぞれが呼び出し元の義務に対応します。

- **`allow`** — アクションは許可されています。続行します。
- **`deny`** — アクションは禁止されており、`deniedAction` が示されます。呼び出し元はそれを実行してはなりません。
- **`principal_disabled`** — 主体が無効です。特定の原因を持つ拒否として扱われます。
- **`invalid_request`** — リクエスト自体が不正形式です。呼び出し元は盲目的に再試行するのではなく、リクエストを修正します。

各決定に対して診断が出力されるため、拒否は観測可能です。`Ankole.AuthZ.Decision.result/1` は決定マップを `:ok | {:error, reason}` に変換します。これは呼び出し元が分岐する形状です。

## 強制が実際に効く場所

AuthZ は agent が回避して話せるレイヤーではありません。ランタイムが重要な境界でそれを参照するためです。

- AIGateway は、検証済みの token からすべての呼び出しの subject を解決し、その subject の grant が到達できる model selector と provider を決定します。
- ツールの準備・ディスパッチ時に `agent:<uid>:tool:<fn>`（アクション `invoke` と正規化済みの `context.request.args`）を評価し、人間起点のターンにおける Pod 操作では `Human ∩ Agent` の権限積集合を適用します。
- 実行セッション Driver は commit 前に永続 fence を確認します。Worker の Job 操作は永続 Job attempt fence と認証済み接続の identity を確認します。
- Site Console（`/api/v2`）および Pod 管理（`/api/v2/pod/admin`）の操作には、検証済みのブラウザ証明、CSRF 保護、そして現在の `site_console:**` または `tenant_console:**` grant が必要です。

モデルが「私は許可されている」と主張することは決してできません。境界が Principal と grant をチェックし、決定に従って行動します。

## 運用者向けの表面

`/api/v2` 配下の Site Console JSON:API ルートが Principal、グループ、grant の管理（`site_console:**`）を公開し、Pod 管理者は `/api/v2/pod/admin/*`（`tenant_console:**`）でテナントのメンバー、招待、設定、Identity Provider を管理します。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/principals` | Principal を一覧表示 |
| `POST` | `/api/v2/principals` | human の内部メンバー Principal を事前作成 |
| `GET` | `/api/v2/principals/:uid` | 1 つの Principal を読み取る |
| `PATCH` | `/api/v2/principals/:uid` | human Principal のプロフィール（`display_name`）を更新 |
| `PATCH` | `/api/v2/principals/:uid/membership` | human Principal の `membership`（`member` または `guest`）を変更 |
| `GET` | `/api/v2/principals/:uid/access` | human のアクセス状態、制限、復元レビュー投影を読み取る |
| `POST` | `/api/v2/principals/:uid/access-disables` | human Principal を一時停止（`suspended`）または退職処理（`offboarded`） |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 制限解除後に無効化された human Principal を復元 |
| `GET` | `/api/v2/principals/:uid/groups` | Principal の group を一覧表示 |
| `GET` | `/api/v2/principals/:uid/grants` | Principal の grant を一覧表示 |
| `GET` | `/api/v2/principal-groups` | group を一覧表示 |
| `POST` | `/api/v2/principal-groups` | operator group を作成 |
| `GET` | `/api/v2/principal-groups/:name` | group を読み取る |
| `PATCH` | `/api/v2/principal-groups/:name` | group を更新 |
| `DELETE` | `/api/v2/principal-groups/:name` | operator group を削除 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | computed group のメンバーをプレビュー |
| `POST` | `/api/v2/permission-grants` | operator permission grant を作成（`/api/v2/permission-grants/:id` で `PATCH`/`DELETE`） |

grant とメンバーシップの管理は `Ankole.AuthZ` を通り、行を書き込む前に owner shape、resource-pattern 構文、CEL condition 構文を検証します。PostgreSQL の check constraint と部分一意インデックスがストレージ層でも同じ不変条件を保証します。

## Principal と AuthZ がそうでないもの

AuthZ はプロンプトの指示でも、期待でもありません。モデルに責任を求めるのではなく、Principal をチェックしてその答えを強制します。Principal は 1 つのインスタンスを別々のエンタープライズ境界に分割するものではなく、リクエストごとのロールでもありません。それは、権限が付与され、グループ化され、評価される、安定した説明責任主体です。kernel は運用者が設定する第二のポリシーエンジンではありません。control plane が組み立てた snapshot を決定論的に評価し、呼び出し元はその決定に従わなければなりません。

## 次のステップ

- 検証済みの token が AIGateway エッジで Principal に解決される仕組みは、[AIGateway API](../ai-gateway/)を参照してください。
- agent Principal の Driver fence が turn をフェンスする仕組みは、[Sessions](../sessions/)を参照してください。
