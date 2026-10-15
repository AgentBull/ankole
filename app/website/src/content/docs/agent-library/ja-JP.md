---
title: Agent Library
description: Agent にできること——Skill はファイル bundle として、Agent Plugin は Codex パッケージとして扱い、Agent ごとに「既定 → 上書き」で解決する有効化モデル。
section: Developer guide
order: 107
---

Agent Library は 1 つの問いに答えます。この Agent は実際には何をすることを許可されているのか。Agent Library とは、デプロイインスタンスが同梱する Skill と Agent Plugin のカタログであり、さらに特定の Agent に対してどれを有効にするかを決める Agent 単位の状態です。このページでは、そのモデルを `Ankole.AIAgent.Library` の実コードに対応付けて説明します。

同梱の Skill と Agent Plugin は、アプリイメージ内のファイル bundle です。インストール済み Skill は、コントロールプレーンが管理する Agent の Files ドライブの `skills/` 配下に保存されます。PostgreSQL はカタログ、有効化状態、正本となるファイル参照を保持し、オブジェクトストアはインストール済みファイルの内容を保持します。Worker はこれらのファイルをローカルの実行キャッシュにダウンロードします。

## 2 種類の能力

library は、関連するが異なる 2 つのものを保持します。

- **Skill** はファイル bundle であり、`SKILL.md` によって識別されます。Skill 名は小文字で英字から始まり、使えるのは英字・数字・`_`・`-` のみで、最大 64 文字です。Skill は `builtin`（アプリイメージに同梱され、`app/library/skills` から同期される）か、`installed`（Agent の Files ドライブの `skills/` 配下に保存される）のどちらかです。`agent_skills` 行は有効化状態、source kind、content hash、同期時刻を記録します——これは明確に、ファイルの中身を保持するテーブルではありません。
- **Agent Plugin** は標準の Codex Plugin パッケージであり、Ankole の任意の `workspace-template/` 初期化ディレクトリを伴うことがあります。パッケージのバイト列とバージョンはインスタンスの library に置かれ、PostgreSQL が保存するのは Agent 単位の疎らな有効化上書きだけです。Plugin 識別子は Skill 名と同じ形式規則に従います。

2 つはつながっています。Agent Plugin は Skill を内包でき、Skill 行は親の有効化とカタログ表示のために `agent_plugin_id` を記録します。ただし Agent Plugin への所属は独立したメタデータであり、Skill の読み込み方法を変えるものではありません。

## 有効化: tenant の既定値と Agent の上書き

tenant 設定が Agent Plugin と Skill の実効既定値を提供します。tenant に上書きがなければ site 設定を継承し、オペレーター設定がなければ同梱カタログの既定値を使います。Agent は自身の上書きだけを保存します。

`effective_enabled` は Agent の上書き、または継承した tenant 既定値です。Plugin member Skill は親 Plugin の有効化も必要です。親を無効にしても member の設定は保持し、親を再び有効にすると適用します。

Console の [Agent Library capabilities](../console-api/) は選択した tenant の既定値を読み書きし、Agent 単位の上書きを許可します。API フィールド名 `global_default_enabled` は維持しますが、値は site 継承を含む、その tenant の実効既定値です。

## Brain からだけ想起する Skill の発見

同梱の standalone Skill または Agent Plugin member は、`brain-recall-only: true` を宣言できます。同梱 Skill は 1 つのグローバルな名前空間を共有するため、Plugin への所属は Skill 名を変えません。Agent がインストールした Skill はこの mode に参加しません。

Agent Library は完全な実効 Skill セットを Worker に送ります。通常の Skill は model に見える Skill カタログへ入ります。Brain からだけ想起する Skill は `skill_view` の読み込み可能な集合に残りますが、カタログからは除外されます。library sweep は名前、説明、tag だけを、`lazyload-agent-skills/<skill-name>` の軽量な Brain レコードとして projection します。Skill の本文、リソース、Agent 固有の教訓は、それぞれを所有する file と database の経路に残ります。

projection は同じテナント内の Agent で共有され、1 つの Agent が Skill を無効にしても削除されません。Brain query と `skill_view` は、その Agent の現在の Plugin と Skill の実効状態をどちらも適用します。そのため、無効なレコードは想起枠を消費せず、読み込むこともできません。能力を再び有効にすると、既存の projection がそのまま利用可能になります。

## Agent の永続ドキュメントと Skill 教訓

能力に加えて、library は Agent 自身の書き込み可能なドキュメントと Agent 固有の Skill 指針を保持します。

- **Agent の永続ドキュメント**は `mission`、`soul`、`design`、`confidentiality_policy` の 4 つで、コンテナテーブルが受け入れる 4 つの `source_kind` 値です。最初の 2 つは責任と振る舞いを定義します。`design` はビジュアル作業のためのデザインシステムを保存します。`confidentiality_policy` は、Agent が Brain に知識を書き込むときの audience 選択を導きます。これらは `agent_library_container_entries` に置かれ、content hash を使用します。
- **Skill 教訓**は `agent_skill_lessons` の変更不可な意味論的 row です。各 row は 1 つの Agent と 1 つの Skill に属し、作成者、証拠、リース状態、廃止履歴を記録します。Dreaming は証拠に基づくリース付き教訓を書きます。運用者はリースのない人の教訓を追加し、任意の教訓を廃止できます。

Skill view は Skill file を読み、配信条件を満たす教訓を `Agent-specific additions` の下に表示します。基礎となる `SKILL.md` は変わりません。証拠、再確認、配信の規則については [Skill 教訓](../skill-lessons/) を参照してください。

## 同期:レジストリの誠実さを保つ

コントロールプレーンの `sync_agent_skills` は、2 種類のソースを 1 つの Agent のカタログにまとめます。

- **同梱の Skill** はアプリイメージから読み取り、standalone Skill と Agent Plugin member を含みます。新しいイメージは、次の同期でこれらの Skill を追加または更新できます。
- **インストール済み Skill** は、Agent の Files ドライブの `skills/<name>/SKILL.md` から直接読み取ります。Library は一覧の全ページと各 manifest を読み取ってからカタログを変更します。追加または変更された manifest はカタログ行を更新し、削除された manifest は対応する行を削除します。読み取りや解析に失敗した場合、カタログは変更されません。更新時には、オペレーターが設定した既存の `enabled_override` を保持します。

Worker はインストール済み Skill を実行キャッシュにダウンロードします。キャッシュを走査してカタログを送信したり置き換えたりすることはありません。内容の hash によって、変更のない行への書き込みを省きます。

## オペレーターの操作面

[Console](../console-api/) ページで既に説明した Console ルートがこのモデルを駆動します。特に能力ルートです。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 選択した tenant のカタログと既定値 |
| `PUT` | `/agent-library/agent-plugins/:id` | plugin の tenant 既定値を設定 |
| `PUT` | `/agent-library/skills/:id` | Skill の tenant 既定値を設定 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 1 つの Agent の実効能力 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 1 つの Agent について plugin を上書き |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 1 つの Agent について Skill を上書き |
| `GET` | `/agents/:agent_uid/library-documents` | その Agent の mission/soul/design/confidentiality policy を一覧表示 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 1 つのドキュメントを設定 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 有効な Skill 教訓と廃止済み教訓を一覧表示 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 人の Skill 教訓を追加 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 教訓を廃止 |

`/agents/:agent_uid/library-capabilities` の読み取りは、アプリイメージと Agent の Files ドライブから Skill を同期します。実行中の Worker は必要ありません。

## Agent Library ではないもの

これはマーケットプレイスでも、ホットロード方式でもありません。Skill と Plugin は信頼された first-party の bundle です。同梱の bundle はデプロイインスタンスと共に出荷され、インストール済み Skill は Agent の Files ドライブに保存されます。サードパーティのディスカバリーはなく、worker が既に提供するもの以外の分離機構もありません。library は model の tool を定義する場所ではなく、オペレーターが Agent の Turn で使用できる能力を決める場所です。実行時に control plane が主 Agent の Skill 指示を読み、Worker がコンピュータツールと Codex Job の Skill を準備します。

## 次のステップ

- library を設定するルートについては、[Console](../console-api/) ページを読んでください。
- Agent 固有の作業指針については、[Skill 教訓](../skill-lessons/) をお読みください。
- Turn 中に有効化された Skill を実行する worker については、[Sessions](../sessions/) ページを読んでください。
- library がスコープされる Agent の Principal については、[Principal and AuthZ](../principal-authz/) を読んでください。
