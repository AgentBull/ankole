---
title: Agent Library
description: Agent にできること——Skill はファイルシステム上の bundle として、Agent Plugin は Codex パッケージとして扱い、Agent ごとに「既定 → 上書き」で解決する有効化モデル。
section: Developer guide
order: 107
---

Agent Library は 1 つの問いに答えます。この Agent は実際には何をすることを許可されているのか。Agent Library とは、デプロイインスタンスが同梱する Skill と Agent Plugin のカタログであり、さらに特定の Agent に対してどれを有効にするかを決める Agent 単位の状態です。このページでは、そのモデルを `Ankole.AIAgent.Library` の実コードに対応付けて説明します。

決定的な性質を先に述べます。Skill と plugin は、それ自体がファイルシステム上の bundle であり、データベースの行ではありません。PostgreSQL が保持するのは、有効化状態、レジストリの意味論、ファイルの観測結果——つまり、インスタンス全体の既定値の上に載る、Agent 単位の疎らな上書きです。バイト列とバージョンはインスタンスの library に置かれたままになり、データベースはだれが何を有効にしているかを記録するだけです。

## 2 種類の能力

library は、関連するが異なる 2 つのものを保持します。

- **Skill** はファイルシステム上の bundle であり、`SKILL.md` によって識別されます。Skill 名は小文字で英字から始まり、使えるのは英字・数字・`_`・`-` のみで、最大 64 文字です。Skill は `builtin`（アプリイメージに同梱され、`app/library/skills` から同期される）か、`installed`（worker から見える storage 配下に Agent がインストールする）のどちらかです。`agent_skills` 行は有効化状態、source kind、content hash、同期時刻を記録します——これは明確に、ファイルの中身を保持するテーブルではありません。
- **Agent Plugin** は標準の Codex Plugin パッケージであり、Ankole の任意の `workspace-template/` 初期化ディレクトリを伴うことがあります。パッケージのバイト列とバージョンはインスタンスの library に置かれ、PostgreSQL が保存するのは Agent 単位の疎らな有効化上書きだけです。Plugin 識別子は Skill 名と同じ形式規則に従います。

2 つはつながっています。Agent Plugin は Skill を内包でき、Skill 行は親の有効化とカタログ表示のために `agent_plugin_id` を記録します。ただし Agent Plugin への所属は独立したメタデータであり、Skill の読み込み方法を変えるものではありません。

## 有効化:既定、そして上書き

Agent の実効的な能力は、2 つの層を持ってカタログを走査することで解決されます。

1. **インスタンス全体の既定値**——各 Skill の `default_enabled` と、オペレーターが設定する plugin 全体の既定値。
2. **Agent 単位の上書き**——Skill 行の `enabled_override`、または 1 つの Agent に限定された Agent Plugin の上書き。

解決結果は、能力エンドポイントが返す `effective_enabled` フィールドです。既定値を取り、上書きがあればそれを適用します。上書きのない能力は既定値を継承し、上書きのある能力は上書きに従います。カタログは 256 個の plugin に制限されているため、解決は安価で、表面は読みやすさを保てます。

これが、Console の [Agent Library の能力](../console-api/) ルートが公開するモデルです。全体の既定値を設定し、その後 Agent ごとに狭めたり広げたりします。

## Brain からだけ想起する Skill の発見

同梱の standalone Skill または Agent Plugin member は、`brain-recall-only: true` を宣言できます。同梱 Skill は 1 つのグローバルな名前空間を共有するため、Plugin への所属は Skill 名を変えません。Agent がインストールした Skill はこの mode に参加しません。

Agent Library は完全な実効 Skill セットを Worker に送ります。通常の Skill は model に見える Skill カタログへ入ります。Brain からだけ想起する Skill は `skill_view` の読み込み可能な集合に残りますが、カタログからは除外されます。library sweep は名前、説明、tag だけを、`lazyload-agent-skills/<skill-name>` の軽量な Brain レコードとして projection します。Skill の本文、リソース、Agent 固有の教訓は、それぞれを所有する file と database の経路に残ります。

projection は instance で共有され、1 つの Agent が Skill を無効にしても削除されません。Brain query と `skill_view` は、その Agent の現在の Plugin と Skill の実効状態をどちらも適用します。そのため、無効なレコードは想起枠を消費せず、読み込むこともできません。能力を再び有効にすると、既存の projection がそのまま利用可能になります。

## Agent の永続ドキュメントと Skill 教訓

能力に加えて、library は Agent 自身の書き込み可能なドキュメントと Agent 固有の Skill 指針を保持します。

- **Agent の永続ドキュメント**は `mission`、`soul`、`design`、`confidentiality_policy` の 4 つで、コンテナテーブルが受け入れる 4 つの `source_kind` 値です。最初の 2 つは責任と振る舞いを定義します。`design` はビジュアル作業のためのデザインシステムを保存します。`confidentiality_policy` は、Agent が Brain に知識を書き込むときの audience 選択を導きます。これらは `agent_library_container_entries` に置かれ、content hash を使用します。
- **Skill 教訓**は `agent_skill_lessons` の変更不可な意味論的 row です。各 row は 1 つの Agent と 1 つの Skill に属し、作成者、証拠、リース状態、廃止履歴を記録します。Dreaming は証拠に基づくリース付き教訓を書きます。運用者はリースのない人の教訓を追加し、任意の教訓を廃止できます。

Skill view は Skill file を読み、配信条件を満たす教訓を `Agent-specific additions` の下に表示します。基礎となる `SKILL.md` は変わりません。証拠、再確認、配信の規則については [Skill 教訓](../skill-lessons/) を参照してください。

## 同期:レジストリの誠実さを保つ

Skill はファイルシステム上の bundle なので、データベースのレジストリはファイルシステムを追跡しなければなりません。2 つの同期パスがそれを担います。

- **`sync_builtin_skills`** は `app/library/skills` ツリーを builtin Skill 行と reconcile し、変更があったかどうか、content hash、Skill 数とファイル数を返します。これはアプリイメージから実行されるため、新しいイメージは次の同期で builtin Skill を追加または更新できます。
- **`sync_agent_skills`** は、1 つの Agent のインストール済み Skill を、worker から見える storage が実際に示す内容と reconcile し、`replace_installed_skill_observations` が観測したファイル集合を書き込みます。storage から消えた Skill はレジストリに反映され、現れた Skill は拾い上げられます。

同期は読み取りと対帳であり、投げっぱなしではありません。`content_hash` が同期を冪等にします。同じツリーは同じ hash を生成し、実際の変更のみが行を書き込みます。

## オペレーターの操作面

[Console](../console-api/) ページで既に説明した Console ルートがこのモデルを駆動します。特に能力ルートです。

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 既定値を含む全体カタログ |
| `PUT` | `/agent-library/agent-plugins/:id` | plugin の全体既定値を設定 |
| `PUT` | `/agent-library/skills/:id` | Skill の全体既定値を設定 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 1 つの Agent の実効能力 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 1 つの Agent について plugin を上書き |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 1 つの Agent について Skill を上書き |
| `GET` | `/agents/:agent_uid/library-documents` | その Agent の mission/soul/design/confidentiality policy を一覧表示 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 1 つのドキュメントを設定 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 有効な Skill 教訓と廃止済み教訓を一覧表示 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 人の Skill 教訓を追加 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 教訓を廃止 |

`/agents/:agent_uid/library-capabilities` の読み取りは agent-skill 同期をトリガーするため、オペレーターが見るのは現在の storage と対帳されたレジストリであり、古いスナップショットではありません。

## Agent Library ではないもの

これはマーケットプレイスでも、ホットロード方式でもありません。Skill と plugin は信頼された first-party の bundle であり、デプロイインスタンスと共に出荷されるか、worker から見える storage にインストールされます。サードパーティのディスカバリーはなく、worker が既に提供するもの以外の分離機構もありません。データベースは Skill のバイト列の供給源ではありません——バイト列はファイルシステム上にあり、レジストリは見えるものだけを追跡します。そして library は model の tool を定義する場所でもありません。library は、オペレーターが、Agent を 1 つの Turn に持ち込める能力を決める場所です。「有効」から「実際に呼び出される」への移行は、Turn の時点での Agent Computer Worker の仕事です。

## 次のステップ

- library を設定するルートについては、[Console](../console-api/) ページを読んでください。
- Agent 固有の作業指針については、[Skill 教訓](../skill-lessons/) をお読みください。
- Turn 中に有効化された Skill を実行する worker については、[Actor Runtime](../actor-runtime/) ページを読んでください。
- library がスコープされる Agent の Principal については、[Principal and AuthZ](../principal-authz/) を読んでください。
