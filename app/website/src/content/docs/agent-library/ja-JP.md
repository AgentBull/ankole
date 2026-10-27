---
title: Agent Library
description: Agent に許可された能力の管理モデル。Skill はファイルバンドル、Agent Plugin は Codex パッケージとして扱い、Agent ごとに「既定 → 上書き」で有効化状態を解決します。
section: Developer guide
order: 107
---

Agent Library は、「各 Agent にどの能力の使用を許可するか」を管理する仕組みです。デプロイ環境に同梱された Skill と Agent Plugin のカタログに加え、Agent ごとにどの項目を有効にするかという設定状態を保持します。このページでは、そのモデルを `Ankole.AIAgent.Library` の実装に対応付けて解説します。

同梱の Skill と Agent Plugin はアプリケーションイメージ内にファイルバンドルとして含まれており、後からインストールされた Skill は、control plane が管理する Agent の Files ドライブ上の `skills/` 配下に保存されます。カタログ情報、有効化状態、正本となるファイル参照は PostgreSQL が保持し、インストール済みファイルの実体はオブジェクトストアに格納されます。Worker は必要なファイルをローカルの実行キャッシュへダウンロードして利用します。

## 2 種類の能力

Agent Library では、互いに関連しつつ役割の異なる 2 種類の能力を扱います。

- **Skill** は `SKILL.md` で識別されるファイルバンドルです。Skill 名は英小文字で始まり、英小文字・数字・`_`・`-` のみを使用でき、最大 64 文字です。種類には `builtin`（アプリイメージに同梱され、`app/library/skills` から同期されるもの）と `installed`（Agent の Files ドライブの `skills/` 配下に保存されるもの）の 2 つがあります。データベースの `agent_skills` テーブルには有効化状態、source kind、content hash、同期時刻が記録されますが、ファイルの中身そのものはこのテーブルには格納されません。
- **Agent Plugin** は標準の Codex Plugin パッケージであり、必要に応じて Ankole 固有の `workspace-template/` 初期化ディレクトリを含めることができます。パッケージのバイナリやバージョン情報はインスタンスのライブラリ側に置かれ、PostgreSQL には Agent ごとに上書きされた有効・無効の差分設定だけが保存されます。Plugin 識別子の命名規則は Skill 名と同じです。

この 2 つは連携させることも可能です。Agent Plugin の内部に Skill を含めることができ、その場合 Skill レコードには親 Plugin の有効化状態やカタログ表示と連動するための `agent_plugin_id` が記録されます。ただし、Agent Plugin への所属はあくまで管理上のメタデータであり、Skill の読み込み方法自体が変わるわけではありません。

## 有効化: tenant の既定値と Agent の上書き

Agent Plugin と Skill の既定の有効・無効はテナント設定によって決まります。テナント側で上書き設定がなければサイト設定を継承し、運用者による設定が一切ない場合は同梱カタログの初期値が使われます。各 Agent には、そこから変更したい上書き設定だけを保存します。

実際に適用される `effective_enabled` は、Agent 個別の上書き値（未設定なら継承されたテナント既定値）から算出されます。なお、Plugin に含まれるメンバー Skill が有効になるには、親である Agent Plugin 自体も有効になっていなければなりません。親 Plugin を無効化してもメンバー Skill 個別の設定値は消えずに保持され、親を再び有効化すると元の設定がそのまま適用されます。

Console の [Agent Library capabilities](../console-api/) ルートを使うと、選択中のテナントの既定値を読み書きしたり、Agent 単位の上書きを設定したりできます。API レスポンスの `global_default_enabled` フィールドには、サイト設定からの継承も加味した、そのテナントにおける実効既定値が返されます。

## Brain からだけ想起する Skill の発見

同梱の standalone Skill や Agent Plugin のメンバー Skill には、`brain-recall-only: true` を指定できます。同梱 Skill は単一のグローバルな名前空間を共有するため、Plugin に属していても Skill 名は変わりません。なお、Agent が後からインストールした Skill ではこのモードを利用できません。

Agent Library は有効なすべての Skill セットを Worker へ渡しますが、モデルから見える Skill カタログに載るのは通常の Skill だけです。`brain-recall-only` が指定された Skill はカタログからは除外され、`skill_view` で読み込み可能な対象としてのみ保持されます。その代わり、library sweep 処理によって名前・説明・タグだけが抽出され、`lazyload-agent-skills/<skill-name>` という軽量な Brain レコードとして投影（projection）されます。Skill の本文や付属リソース、Agent 固有の教訓は、それぞれのファイルおよびデータベースの保存先にそのまま残ります。

この投影レコードは同一テナント内の Agent 間で共有されており、ある Agent が該当 Skill を無効化してもレコード自体は削除されません。その代わり、Brain 検索時と `skill_view` 実行時の両方で、対象 Agent における現在の Plugin・Skill の実効状態がチェックされます。そのため、無効化されている Skill が想起枠を消費することはなく、内容を読み込むこともできません。後から再び有効化すれば、既存の投影レコードをそのまま利用できます。

## Agent の永続ドキュメントと Skill 教訓

Agent Library は能力カタログだけでなく、Agent 自身の書き込み可能な永続ドキュメントと、Agent 固有の Skill 教訓も管理します。

- **Agent の永続ドキュメント**には `mission`、`soul`、`design`、`confidentiality_policy` の 4 種類があり、これらがコンテナテーブルで許可される `source_kind` の値に対応します。最初の 2 つは Agent の責務と振る舞いを定義し、`design` は視覚的な制作物のデザインシステムを保持します。`confidentiality_policy` は、Agent が Brain に知識を書き込む際の公開範囲（audience）の判断基準を定めます。これらはいずれも `agent_library_container_entries` テーブルに格納され、content hash で管理されます。
- **Skill 教訓**は `agent_skill_lessons` テーブルに記録されるイミュータブルなレコードです。各レコードは特定の Agent と特定の Skill に紐付き、作成者、根拠となる証拠、リース状態、廃止履歴を保持します。Dreaming 処理は根拠に基づくリース付きの教訓を作成し、運用者は期限リースのない人間由来の教訓を追加したり、任意の教訓を廃止したりできます。

`skill_view` で Skill を参照すると、元の `SKILL.md` を書き換えることなく、配信条件を満たす教訓が `Agent-specific additions` セクションとして末尾に付加されます。根拠の検証、再確認、配信条件の詳細については、[Skill 教訓](../skill-lessons/) を参照してください。

## 同期:レジストリの誠実さを保つ

control plane の `sync_agent_skills` は、次の 2 つのソースから情報を集めて各 Agent のカタログを最新の状態に保ちます。

- **同梱の Skill**: アプリイメージから直接読み取られます（standalone Skill と Agent Plugin メンバーの両方を含みます）。新しいイメージをデプロイすると、次回の同期時にこれらの Skill が追加・更新されます。
- **インストール済み Skill**: Agent の Files ドライブにある `skills/<name>/SKILL.md` から直接読み取られます。同期処理では、ファイル一覧の全ページと各マニフェストをすべて読み終えてからカタログを更新します。マニフェストが追加・変更されていればカタログ行を更新し、削除されていれば対応する行も削除します。途中で読み取りやパースに失敗した場合は、カタログは一切変更されません。また、更新時にも運用者が設定した既存の `enabled_override` はそのまま維持されます。

Worker はインストール済み Skill をローカルの実行キャッシュへダウンロードして使いますが、キャッシュ側を走査してカタログを上書き・送信することはありません。また、content hash を比較することで、内容が変わっていない行への不要な書き込みを省いています。

## オペレーターの操作面

[Console](../console-api/) ページで紹介している Console API ルート（特に capabilities 関連ルート）から、このモデルを操作できます。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 選択中のテナントのカタログと既定値を取得 |
| `PUT` | `/agent-library/agent-plugins/:id` | Plugin のテナント既定値を設定 |
| `PUT` | `/agent-library/skills/:id` | Skill のテナント既定値を設定 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 特定の Agent の実効能力を取得 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 特定の Agent に対して Plugin 設定を上書き |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 特定の Agent に対して Skill 設定を上書き |
| `GET` | `/agents/:agent_uid/library-documents` | 対象 Agent の mission / soul / design / confidentiality policy を一覧取得 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 指定した種類の永続ドキュメントを更新 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 有効な Skill 教訓および廃止済み教訓を一覧取得 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 人間による Skill 教訓を追加 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 教訓を廃止 |

`/agents/:agent_uid/library-capabilities` を読み取ると、アプリイメージおよび Agent の Files ドライブから Skill が同期されます。このとき Worker が起動している必要はありません。

## Agent Library ではないもの

Agent Library はマーケットプレイスではなく、ホットロード機構でもありません。Skill と Plugin はいずれも信頼されたファーストパーティのバンドルであり、同梱バンドルはデプロイイメージに含まれ、インストール済み Skill は Agent の Files ドライブに格納されます。サードパーティ製パッケージの自動検索機能はなく、Worker が備える境界以上の追加サンドボックスもありません。また、モデルのツール定義そのものを記述する場所でもなく、あくまで「各 Agent が Turn 中にどの能力を使えるか」を運用者が制御するための仕組みです。実際の実行時には、control plane がメイン Agent 向けの Skill 指示を読み取り、Worker がコンピュータツールや Codex Job 向けの Skill を準備します。

## 次のステップ

- Agent Library を操作する API ルートの詳細については、[Console](../console-api/) を参照してください。
- Agent 固有の作業指針の仕組みについては、[Skill 教訓](../skill-lessons/) を参照してください。
- Turn の実行中に有効な Skill を動かす Worker の仕組みについては、[Sessions](../sessions/) を参照してください。
- Agent Library のスコープ単位となる Agent の Principal については、[Principal and AuthZ](../principal-authz/) を参照してください。
