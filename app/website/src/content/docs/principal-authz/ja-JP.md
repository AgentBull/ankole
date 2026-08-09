---
title: Principal と AuthZ
description: Ankole デプロイメントインスタンスの権限境界 — 説明責任のある主体としての Principal、権限 grant、グループメンバーシップ、プロンプトの慣習ではなくランタイムによる強制。
section: Developer guide
order: 106
---

Ankole のすべてのアクション（人のサインイン、agent による turn の実行、job による owner の wake、Brain への書き込み）は Principal が実行し、その Principal が何をできるかはアクションの時点で AuthZ が決定します。このページでは、その境界を `Ankole.Principals` と `Ankole.AuthZ` の実際のコードに照らして説明します。

最初に決定的な性質を述べます。認可はランタイムの事実であり、境界で強制されるものであって、モデルに求める慣習ではありません。Principal は永続的で説明責任のある主体であり、その grant は PostgreSQL に保存され、チェックされるすべてのアクションは kernel が明示的な snapshot に対して評価し、呼び出し元はその決定に従わなければなりません。

## Principal: 1 つの説明責任ある主体

Principal は、人、agent、system service が共有する永続的な説明責任主体です。`principals` テーブルは `uid`（型付きの `PrincipalKey`。check constraint により lowercase と存在が強制される）をキーとし、各行は `:human`、`:agent`、`:system` のいずれかの `type` と、`:active` または `:disabled` の `status` を持ちます。

人の Principal は 1 つの `HumanUser` と任意の数の `ExternalIdentity` 行（運用者がフェデレーションした identity）を持ちます。agent の Principal は 1 つの `Agent` 行を持ちます。両方を 1 つのテーブルに通す意義は、説明責任の形状が 1 つであることです。何かを実行した者には、それを実行した Principal 行が存在し、すべての audit 行、grant、グループメンバーシップが指す安定した uid を持ちます。

無効化された Principal は部分的に使えるわけではありません。kernel の決定は無効な主体に対して `principal_disabled` を返すため、Principal を無効化すると、すべての grant を追いかけることなく、インスタンス全体でその権限が除去されます。

## grant: 誰が何をできるか

権限 grant は正確に 1 つの Principal または正確に 1 つの Principal group に属します。両方やどちらでもない場合はなく、`validate_owner_shape` とデータベースの check constraint で強制されます。grant は次の要素を持ちます。

- `resource_pattern` — grant が対象とするもの。構文は `Input.validate_resource_pattern_syntax` で検証されます。
- `action` — grant が許可するもの。コロンは許可されません（コロンは resource/action の区切りに予約されています）。
- `condition` — ブール式。デフォルトは `"true"` で、`Input.validate_condition_syntax` で検証されます。
- 運用者が読むための `description` と `metadata`。

grant は精神としては append-only であり、所有者ごとに自然キーで一意です（Principal ごとに 1 つ、グループごとに 1 つ。自然インデックス上の関係）。grant の作成、upsert、更新は control plane の操作であり、呼び出し元がデータベースに拒否される owner shape を指す grant を構築することはできません。

## Group: 静的および計算によるメンバーシップ

Principal group は名前付きの集合で、Principal はこれを介して grant を受けることができます。これにより、Principal ごとの行なしで権限をスケールできます。group は `domain`（`:operator`、`:directory`、`:im_group`）、`kind`（`:static` または `:computed`）、および computed group 用のオプションの `computed_condition` を持ちます。

2 つの組み込み group がデプロイメントインスタンスをシードします。`admin` group は運用者の権限面です。`all_humans` group は計算条件 `principal.type == "human" && principal.status == "active"` を持つため、誰も手動でリストを保守しなくても、すべてのアクティブな人がメンバーになります。静的メンバーシップは `principal_group_memberships` に保存され、計算によるメンバーシップは snapshot に対して評価されます。外部ディレクトリ（IdP、IM プラットフォーム）は external binding を通じて group に同期できるため、運用者はすでに信頼しているディレクトリに AuthZ を向けられます。

## 決定がどのように行われるか

control plane と kernel は意図的に作業を分割しており、この分割こそが AuthZ が助言ではなく強制可能である理由です。

- **control plane は状態と snapshot の組み立てを所有します。** チェック対象のアクションについて、Principal、その grant、グループメンバーシップ、関連する resource context を読み込み、明示的な認可 snapshot を組み立てます。
- **kernel は決定論的なルール評価を所有します。** snapshot の grant と condition を評価し、決定を返します。入力が明示的な snapshot でルールが決定論的であるため、同じ snapshot は毎回同じ答えを返し、in-memoryキャッシュがずれることはありません。

公開エントリポイントは `AuthZ.authorize(principal_uid, resource, action, context)`、ブール値を返す `allowed?/4`、1 つのリソースに対するアクションのバッチ用の `authorize_all`、完全な決定マップを返す `_decision` バリアントです。どれも snapshot を組み立てて kernel に渡し、Principal が何をできるかという呼び出し元の主張を信頼するものはありません。

## 決定ステータス

決定は 4 つのステータスのいずれかで返り、それぞれが呼び出し元の義務に対応します。

- **`allow`** — アクションは許可されています。続行します。
- **`deny`** — アクションは禁止されており、`deniedAction` が示されます。呼び出し元はそれを実行してはなりません。
- **`principal_disabled`** — 主体が無効です。特定の原因を持つ拒否として扱われます。
- **`invalid_request`** — リクエスト自体が不正形式です。呼び出し元は盲目的に再試行するのではなく、リクエストを修正します。

各決定に対して診断が出力されるため、拒否は観測可能です。`AuthZ.result/1` は決定を `:ok | {:error, reason}` に変換します。これは呼び出し元が分岐する形状です。

## 強制が実際に効く場所

AuthZ は agent が回避して話せるレイヤーではありません。ランタイムが重要な境界でそれを参照するためです。

- AIGateway は、検証済みの token からすべての呼び出しの subject を解決し、その subject の grant が到達できる model selector と provider を決定します。
- Actor Runtime は、agent Principal が所有する activation で各 turn をフェンスします。他の subject からの返信はそのフェンスで失敗します。
- Brain は、会話宣言と所有者 Principal を通じてすべての読み書きをスコープします。書き込みの権限モードは payload ではなく actor から導出されます。
- Console の操作は検証済みの admin token を通じて実行され、admin Principal のグループメンバーシップが変更できる範囲を決定します。

モデルが「私は許可されている」と主張することは決してできません。境界が Principal と grant をチェックし、決定に従って行動します。

## 運用者向けの表面

Console スコープのルートは、AuthZ モデルを検査と管理のために公開します。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/principals` | Principal を一覧表示 |
| `GET` | `/principals/:uid` | 1 つの Principal を読み取る |
| `GET` | `/principals/:uid/groups` | Principal の group を一覧表示 |
| `GET` | `/principals/:uid/grants` | Principal の grant を一覧表示 |
| `GET` | `/principal-groups` | group を一覧表示 |
| `POST` | `/principal-groups` | group を作成 |
| `GET` | `/principal-groups/:name` | group を読み取る |
| `PATCH` | `/principal-groups/:name` | group を更新 |
| `POST` | `/principal-groups/computed-member-previews` | computed group のメンバーをプレビュー |

grant とメンバーシップの管理は AuthZ ファサードを通ります。ファサードは、行が書き込まれる前に owner shape、resource-pattern 構文、condition 構文を検証します。データベースの check constraint が最後の防壁です。owner-shape または no-colon ルールに違反する行は存在できません。

## Principal と AuthZ がそうでないもの

AuthZ はプロンプトの指示でも、期待でもありません。モデルに責任を求めるのではなく、Principal をチェックしてその答えを強制します。Principal は 1 つのインスタンスを別々のエンタープライズ境界に分割するものではなく、リクエストごとのロールでもありません。それは、権限が付与され、グループ化され、評価される、安定した説明責任主体です。kernel は運用者が設定する第二のポリシーエンジンではありません。control plane が組み立てた snapshot を決定論的に評価し、呼び出し元はその決定に従わなければなりません。

## 次のステップ

- 検証済みの token が AIGateway エッジで Principal に解決される仕組みは、[AIGateway API](../ai-gateway/)を参照してください。
- agent Principal の activation が turn をフェンスする仕組みは、[Actor Runtime](../actor-runtime/)を参照してください。
- Brain が actor から書き込み権限を導出する仕組みは、[Brain](../brain/)ページを参照してください。