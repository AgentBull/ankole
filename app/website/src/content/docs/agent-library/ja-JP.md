---
title: Agent Library
description: Agent に許可された能力の管理モデル。Skill はファイルバンドル、Agent Plugin は Codex パッケージとして扱い、Agent ごとに「既定 → 上書き」で有効化状態を解決します。
section: Developer guide
order: 107
---

Agent Library は、Agent が有効にしている Skill と Agent Plugin を解決します。共有 Skill の保存先は Pod の `/AnkoleBrain/skills/<name>` です。ホームページは知識ページ、スクリプトやテンプレートはその配下のファイルになります。Agent 専用の Skill は Files 領域の `skills/` にインストールできます。内容、権限、有効化状態は PostgreSQL が保持し、Worker には実行用のコピーを配置します。

## 能力と有効化

Skill は `SKILL.md` を持ち、名前は全体で一意の小文字識別子です。Agent Plugin は関連 Skill と任意の `workspace-template/` をまとめます。有効化は出荷時の既定値、サイトとテナントの設定、Agent 個別設定の順に解決します。Plugin に含まれる Skill には、親 Plugin の有効化も必要です。

有効化と閲覧権限は独立しています。カタログには現在の会話で閲覧できる有効な Skill が並びます。人が開始した Turn では Agent、依頼者、適用対象のルーム参加者が共通して読める範囲を使い、無人の自動処理では Agent 自身の権限を使います。カタログには名前と説明を載せ、本文は `skill_view` で読み込みます。

## 内容の編集と更新

共有 Skill は Pod で編集します。閲覧可能な知識子ページは Skill の指示に追加されますが、`metadata.role = "reference"` の章は必要なときに子パスから読み込みます。Agent 専用の承認済み指針については [Skill lessons](../skill-lessons/) を参照してください。

起動時とカタログ同期時に、Ankole は公式パッケージを保存済みの基準と照合します。対象はホームページのメタデータと本文、および管理対象ファイルのパス、内容ハッシュ、モードです。ローカル変更がなければ、ファイルの追加と削除を含めて一括更新します。変更があればパッケージ全体を保持し、確認待ちの上流ハッシュを記録します。テナント独自の補足ページとファイルは照合対象に含めません。

## Agent の規約

`/AnkoleBrain/AGENTS.md` が組織の行動原則と責務を、`/AnkoleBrain/DESIGN.md` が視覚表現の規約を定義します。`/AnkoleBrain/agents/<uid>/AGENTS.md` は個別の責務を追加し、`AGENTS.override.md` は全体を置き換えます。DESIGN も同様に、本文の追加とメタデータのマージ、または全体の置換を選べます。空の override は継承内容を意図的に空にします。

個人アシスタントのページは所有者とアシスタントだけが閲覧でき、所有者が管理します。組織の Agent は既定で共通規約を継承し、必要な場合だけ個別の規約ページを作成します。

Console では有効な能力を確認し、規約の編集は Pod へのリンクから行います。`GET /agents/:agent_uid/library-documents` は有効な AGENTS と DESIGN、および参照元ページを返します。Worker は各 Turn で `~/AGENTS.md`、`~/DESIGN.md`、`$CODEX_HOME/AGENTS.md` を更新し、プロジェクトの指示ファイルはプロジェクト側で管理します。

インストールは [Skills](../skills/)、実行経路は [Prompt assembly](../prompt-assembly/)、API は [Console](../console-api/) を参照してください。
