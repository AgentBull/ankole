---
title: Agents
description: Console で Agent を作成し、所有者、永続ドキュメント、モデル、能力、環境変数を設定する方法を説明します。
section: User guide
order: 13
---

Agent は、Ankole Agent Harness 内で継続的に稼働する作業主体です。各 Agent は固有のミッション、所有者、アクセス権、ツール、モデルプロファイル、永続ファイル領域を持ちます。

また、許可された知識境界の範囲内で Company Brain を利用し、**Pod** ワークスペースや Signal routing ルールで接続された外部チャットチャネル上で協働します。

## 個人アシスタントと AI 同僚

`Ankole.Principals` では、Agent を次の 2 つのサブタイプとして扱います。

- **個人アシスタント（`personal_assistant`）** — 有効な内部 Human `member` ごとに初回利用時に 1:1 で自動プロビジョニングされます（初期 UID は `<owner_uid>_assistant`）。Unified Drive、Pod の Docs・Base、`all_humans` などのコラボレーションリソースに対しては所有者である人間の権限を投影して動作し（`site_console:**` および `tenant_console:**` の管理スコープは除く）、group memory の開示モードは `strict` 固定、所有者も変更不可です。規約と Skill バインディングを閲覧・編集できるのは所有者本人のみで、所有者が一時停止・退職処理・外部 `guest` への変更を受けた場合は自動的に無効化されます。
- **AI 同僚（`ai_colleague`）** — チーム横断の専門ロール向けに運用者が作成する共有 Agent です。Drive、Pod、Workflow、スケジュール、Background Agent Job のすべてにおいて Agent 自身の Principal 権限で動作し、人間の承認が必要な操作では `propose_action_card` で承認カードを提示します。また、`send_to_agent` を使って分離された `agent_peer` 会話で他の Agent に作業を委譲できます。

## AI 同僚を作成する

1. **Console → Agents**（または Pod のワークスペース設定）を開き、**New Agent** を選択します。
2. 表示名を入力し、テナント内で意味のわかる小文字の `uid`（`^[a-z0-9][a-z0-9._@+-]{0,95}$`、`research-analyst` など）を指定します。Agent はテナント内で `(tenant_id, uid)` として一意に識別されます。
3. ロール、アバター URL（任意）、および `WorkerProvider` を設定します。
4. Agent の所有者となる人間の Principal と、group memory の開示モードを選択します。
5. Agent を保存し、規約、モデルプロファイルの上書き、Agent 固有の環境変数を構成します。

ロールには「Research Analyst」や「Customer Support」など、担当業務の短い要約を入力します。具体的な行動規範・責務とビジュアルデザイン規則は、**Meta Ankole → Agents** にある 2 つの規約ドキュメント（`AGENTS.md` と `DESIGN.md`）で定義します。

`WorkerProvider` では、Agent が使用する [WorkerProvider](../worker-providers/) を指定します。指定を省略した場合はサイトの既定 provider が使われますが、既定 provider が存在しない場合は作成に失敗します（保存後の変更はできません）。同じ provider を共有する Agent 同士であっても、それぞれ専用の Worker インスタンス、`/drive` FUSE マウント、永続 `/workspace` Home が割り当てられます。Agent を保存すると、初回の Worker 起動がバックグラウンドでキューに入ります。初回起動が完了し、アイドル状態の Worker が解放された後は、コンピュータ上の作業が必要なときに control plane が再び起動します。

## 所有者と group memory の開示を設定する

すべての Agent には所有者の設定が必須です。所有者は、その Agent が作成・保持する知識や、その Agent が閲覧対象（audience）に含まれる知識を確認できます。ただし、所有者自身が特定の Group のメンバーでない場合、Agent の所有者であることだけを理由にその Group 限定の知識を読み取ることはできません。

group memory の開示モードは、複数のメンバーが回答を閲覧できる場面で Agent がどこまで知識を開示してよいかを制御します。

- **Strict**: グループ会話に参加している全員が、その記憶アイテムの audience スコープを満たしている必要があります。
- **Relaxed**: 質問者本人の権限だけを確認します。会話に他の参加者がいても、検索結果が絞り込まれることはありません。

ダイレクトメッセージではどちらのモードでも同じ動作になります。グループ内でより広い情報共有を明示的に許容している場合を除き、通常は **Strict** を選択してください。知識境界と開示制御の全体像については、[Brain](../brain/) を参照してください。

## Agent の規約を設定する

**Meta Ankole → Agents** で全体の基準または個別 Agent の `AGENTS.md` と `DESIGN.md` を編集します。`AGENTS.md` は行動と責務、`DESIGN.md` は Web ページ、スライド、文書、図表の視覚表現を定義します。

各 Agent の規約は、全体の基準を継承、追記、または置換できます。DESIGN のメタデータにはデザイントークン、本文には適用方法を記述します。個人アシスタントの設定を閲覧・編集できるのは所有者本人だけです。[Agent Library](../agent-library/) を参照してください。

保存した変更は、Codex Job の再開を含む次の Turn から適用されます。現在の Turn は開始時に全文を読み込んだ規約を使います。

## モデルを設定する

Agent のモデルプロファイルは、**Console → Model Profiles** で構成される 3 層の疎な継承チェーン（`Agent -> Pod -> Site`）に従って解決され、`coding -> heavy -> primary` と `light -> primary` のスロット間フォールバックも適用されます。Site または Pod で `primary` プロファイルが設定されていれば、新しい Agent は個別の上書き設定なしでそのまま稼働できます。この Agent の業務に Pod 既定値とは異なる Provider・モデル階層・カスタム言語モデルエイリアスが必要なスロットだけを上書きしてください。

- Pod 既定値よりも上位または特化したモデルが必要な場合は、`primary`、`light`、または `heavy` を上書きします。
- `primary` がネイティブ画像入力に非対応で、画像の読み取りが必要な場合は `vision_fallback` を設定します。
- Pod 既定値とは異なる Web 検索・閲覧設定が必要な場合は、`web_search` と `web_fetch` を設定します。
- 専用の画像生成 Provider を使う場合は、`image_generate` を設定します。
- Background Agent Job（`coding`）で別の provider やモデルを使いたい場合は **Background Agent Jobs** を設定します（未設定時は `heavy -> primary` にフォールバックします）。ChatGPT サブスクリプションも、[ChatGPT サブスクリプション provider](../chatgpt-subscription-provider/) を通じて同じ手順で選択できます。

独立した `web_search` または `image_generate` プロファイルを使う場合は、対応する provider-hosted スイッチもオフにします。プロファイルの紐付けだけではスイッチは変わりません。両スイッチは既定でオンとなり、Site → Pod → Agent の順で設定を継承します。

モデルを選択・入力する前に、まず Provider を選択してください。Provider を選ぶと context length 欄も入力できるようになります。空欄のままにした場合は、Provider とモデルの既定値が使われます。Agent 側の上書きを削除すると、再び Pod・Site 既定値の継承に戻ります。

詳細設定（Advanced）には、選択した Provider がサポートするオプションだけが表示されます。**Reasoning summary** は Responses API でのみ有効です。**Answer detail** は応答の既定の詳細度を指定し、**Service tier** はこのモデルプロファイルにおけるリクエスト tier を上書きします。指定可能な値は Provider、アカウント、モデルによって異なり、空欄の場合は Provider の既定値が使われます。

最初の LLM Provider とモデルを登録する手順については、[Quick start](../quickstart/#llm-providers) を参照してください。

## token quota を設定する

モデルプロファイルの隣にある **トークンクォータ** セクションでは、一定期間ごとにこの Agent が消費できるトークン数の上限を設定できます。期間の長さ（日数）、期間の開始日時、トークン上限を指定してください。クォータを設定しない場合、上限は設けられません。

設定すると、現在の期間における消費トークン数と上限に対する割合がプログレスバーで表示され、期間の開始日時と終了日時も確認できます。集計対象となるのは、その Agent が行うすべてのモデル呼び出しに対して provider から報告される入力トークンと出力トークンです。これにはスケジュール実行の Turn、Workflow、Background Agent Job のほか、それらの呼び出しに伴って発生する compaction も含まれます。一方、Brain 内部のモデル呼び出し、embedding、Web ツール、画像生成、および人間が自身のトークン枠で行うリクエストは集計対象外です。

トークン消費量が上限に達すると、チャットメッセージに対して通常の回答は行われず、使用済みトークン数・上限・期間の終了日時を知らせる案内メッセージが返されます。また、その Agent の Background Agent Job は次の期間を待たずに失敗終了します。クォータは各モデル呼び出しの直前にチェックされるため、最後の 1 回の呼び出しで消費した分だけ上限を超過して止まることがあります。ブロックされたメッセージは自動再送されないため、期間が切り替わった後にユーザーから再度送信してください。

期間終了を待たずに Agent の稼働を再開したい場合は、**期間をリセット** を実行するとその時点から新しい期間が始まります。**上限を解除** を実行するとクォータ自体が削除されます。いずれの操作を行っても、過去の使用量レコードは監査用に保持されます。その他のコスト制御手段については、[コスト管理](../cost-management/) を参照してください。

## 機能・接続・環境変数を設定する

Agent は既定で、テナントに設定された Agent Plugins と Skills の有効化状態を引き継ぎます。これを変更するには、Pod の **Meta Ankole → Skills**（または **Console → Agent Library**）を開いてテナント既定値を編集するか、対象の Agent に個別の上書き設定を行います。詳しい手順は [Skills](../skills/) および [Agent Library](../agent-library/) を参照してください。

Lark/Feishu、GitHub、Linear などの外部プラットフォーム連携、個人 OAuth アカウント、Skill が宣言するリモート MCP サービスの認証情報は、**Pod → Connections**（`/connectors`）の `Ankole.Connectors` で一元管理し、シークレットを control plane 内に保持します（詳細は [MCP の利用](../using-mcp/) を参照）。Agent 詳細ページの **Environment variables** は、Agent Computer 内のカスタム CLI ツールやスクリプトから参照する環境変数に使用します。同名の変数がある場合、Agent 固有の値はテナント設定やサイト設定を上書きします（詳しくは [環境変数](../worker-env/) を参照）。

## chat channel を接続する

**Pod Chat** では、Signal Binding を別途設定しなくても、ワークスペースのメンバーが自身の個人アシスタントや有効な AI 同僚にダイレクトメッセージ（`dm`）を送ったり、AI 同僚をグループ会話（`group`）へ追加したりできます。また、Agent 同士も `send_to_agent` によって分離された `agent_peer` 会話で直接やり取りできます。

一方、外部の IM チャネルやメールボックスとの連携は Signal Binding で管理します。Slack、Microsoft Teams、Lark、Feishu、DingTalk、WeCom、Telegram、Discord、LINE、WhatsApp、または専用メールボックスからメッセージを受け取るには、**Console → Signal routing** を開いて連携するチャットアプリケーションと宛先の Agent を選択します（対応プラットフォームでは `Ankole.Connectors` の共有接続をそのまま再利用できます）。1 つのチャットアプリケーションに対して複数のルールを作成することも、Agent ごとに別々の Bot アプリケーションを用意することも可能です。詳しくは [Signal routing ルール](../signal-bindings/) を参照してください。

## Agent の変更・UID リネーム・無効化

表示名、ロール、`AGENTS.md` と `DESIGN.md` の規約、モデルプロファイルの上書き、有効な能力はいつでも変更できます。AI 同僚のテナント内 `uid` を変更したい場合は、まず対象の Agent を無効化し、実行中または一時停止中の Worker インスタンスを削除したうえで、監査付きのリネーム操作（`POST /api/v2/agents/:uid/rename` またはワークスペース管理画面）を実行します。これにより、テナント内の grant、グループメンバーシップ、Brain のパスやメンション、Base の参照がトランザクション内で一括更新されます。

Agent を無効化すると新しい作業は受け付けなくなりますが、「無効」ステータスのまま一覧には残ります。その後いつでも再有効化でき、完全に削除することも可能です。削除操作は無効化済みの Agent に対してのみ実行でき、実行するとその Agent のセッション、ジョブ、関連レコードもあわせて削除されます。特定のチャット窓口からの流入だけを止めたい場合は、Agent 自体を無効化するのではなく、該当する Signal routing ルールを無効化してください。

## Agent が応答しない場合

Agent から返信が返らないときは、次の項目を順番に確認してください。

1. 対象の Agent が有効になっていること。
2. Agent に有効な `primary` モデルプロファイルが解決されており（Site/Pod 既定値または Agent 上書き）、LLM Provider が正常に利用できる状態にあること。
3. 外部チャネル経由の場合は、Signal routing ルールが対象の Agent を正しく指していること。
4. コンピュータ上の作業が必要な場合は、**Console → Workers** で Worker が `ready` 状態、またはエラーなく起動中であること。通常の質疑応答には稼働中の Worker は不要です。
5. **Console → Conversations** に該当メッセージが記録されているか、また原因を示すエラーが表示されていないか確認すること。

チャネル別の確認ポイントについては、[Quick start のトラブルシューティング](../quickstart/#agent-not-replying) を参照してください。
