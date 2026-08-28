---
title: 軌跡とメッセージ形式
description: Ankole が会話メッセージとBackground Agent Jobの軌跡をどう保存・プロジェクションするか — 2 つの保存形状、ChatML の正規形式、モデルが見るプロジェクション。
section: Developer guide
order: 121
---

Ankole は agent がしたことを 2 つの場所に、2 種類の作業について記録します。AIGateway は会話メッセージ（ステートフル Responses 会話が生成するライブトランスクリプト）を保存し、Background Agent Jobs はターン軌跡（永続的な Job の実行のターンごとの記録）を保存します。このページは両方の保存形状、正規の ChatML 形式、そしてプロトコル詳細を取り除くモデル可視プロジェクションを説明します。[AIGateway](../ai-gateway/) と [Background Agent Jobs](../background-agent-jobs/) の上に構築されます。

決定的な性質を先に述べます: モデルは生の保存行を決して見ません。両方の形状は、プロトコルのアイデンティティを取り除き、ターンローカルな呼び出しエイリアスに置き換えたモデル可視形式にプロジェクションされます。モデルは内部 UUID やワイヤープロトコルフィールドではなく「ツール呼び出し 1 → ツール結果 1」を見ます。保存形式は永続性と監査のためであり、プロジェクション形式はモデルのためのものです。

## AIGateway 会話メッセージ

AIGateway はライブ会話トランスクリプトを所有します。各メッセージは `ai_gateway_messages` の 1 行です:

| フィールド | 意味 |
|---|---|
| `subject_uid` | 会話が属する Principal |
| `conversation_id` | このメッセージが属する会話 |
| `type` | メッセージタイプ（assistant、tool result など） |
| `role` | メッセージがトランスクリプトで果たすロール |
| `status` | ライフサイクルステータス |
| `previous_message_id` | 自己参照の継続アンカー。API では `previous_response_id` として描画され、会話が連鎖します |
| `content` | メッセージコンテンツ（単一の文字列ではなく、JSON 値） |
| `metadata` | 不透明な呼び出し側メタデータに加え、AIGateway が所有する応答事実（モデル、provider、使用量、provider の生 id）|

`previous_message_id` は継続アンカーです。各メッセージは先行メッセージを指し、連結されたチェーンを生成します。API では `previous_response_id` として描画されるため、呼び出し側や圧縮は任意のアンカーから再開できます。`metadata` フィールドは AIGateway が所有する事実（使用されたモデルと provider、token 使用量、provider の生応答 id）を、不透明な呼び出し側メタデータと並べて運びます。2 つ目のアイテムリストを運んではいけません。

圧縮（[Context compression](../context-compression-and-caching/) を参照）は古いメッセージを、新しいアンカーになる要約メッセージに置き換えます。古いメッセージはモデルの可視コンテキストから消え、要約が新しい出発点になります。

## Background Agent Job の軌跡

Background Agent Jobはターンごとの実行を `background_agent_job_turn_items` の追記専用のサニタイズ済みセマンティックスレッドアイテムのストリームとして保存します。各アイテムは 1 つのターンに属し、ポジション、リビジョン、アイテムキー、セマンティックアイテム本体を持ちます:

| フィールド | 意味 |
|---|---|
| `turn_id` | このアイテムが属する Job ターン |
| `position` | ターン内でのアイテムの順序 |
| `revision` | このアイテムを受理したターンのリビジョン |
| `item_key` | アイテムの安定したキー（`client:` キーは呼び出し元メッセージを示す） |
| `item` | 型付きのセマンティックスレッドアイテム 1 つ |

行は追記専用です。ステアやプロンプトは保存済みアイテムを書き換えず、新しいアイテムを追記します。すべてのリーダーは読み取り時に保存済みアイテムを正規 ChatML メッセージにプロジェクションします。メッセージをプロジェクションしないアイテムもスレッドリプレイのために保存されたままです。アイテムストリーム以前に記録されたターンにはアイテム行がないため、軌跡は空で表示されます。

ツール結果メッセージの metadata は `execution_mechanism` を記録します。モデル Provider が実行したツールには `provider_hosted`、Codex が呼び出した Ankole の動的ツールには `local_dynamic` を使います。この安定した事実により、表示名が同じツールも区別できます。

これは AIGateway 会話メッセージとは別の保存形状です。Background Agent Jobの軌跡は会話ではなく Job に属するからです。Job のターンは独自のスレッドであり、報告先の会話は軌跡ではなく結果を受け取ります。

## モデル可視プロジェクション

モデルは保存行を見ません。worker の `modelVisibleTrajectory` は軌跡を、モデルが見るべきものにプロジェクションします:

- **保存されたプロトコルのアイデンティティを取り除く** — 内部メッセージ id、ワイヤープロトコルフィールド、モデルが作用すべきでないもの。
- **ツール呼び出し id をターンローカルなエイリアスに置き換える** — `call_1`、`call_2` など。モデルはどのツール結果がどのツール呼び出しに属するか（唯一有用な関係）を見ます。それらを配線する内部 UUID は見ません。
- **コンテンツとロールを保持する** — 実際のメッセージ、ツール呼び出しとその結果を、起こった順に。
- **境界付きコンテンツの事実を保持する** — 軌跡レベルの `metadata.redacted` と `metadata.content_truncated` は可視のまま残ります。コントロールプレーンのプロジェクションは、選択したメッセージコンテンツをページ制限に合わせて縮小する必要があるとき、`content_truncated` を設定します。

モジュール doc は明示的です:「ターンローカルな呼び出しエイリアスは、唯一有用な関係、どのツール結果がどのツール呼び出しに属するかを保持する。」保存行が運ぶそれ以外のすべては、モデルのためではなくシステムのためのものです。

## 2 つの形状の関係

| | AIGateway メッセージ | Background Agent Job軌跡 |
|---|---|---|
| 保存するもの | ライブ会話トランスクリプト | ターンごとの Job 実行記録 |
| 所有者 | AIGateway | Background Agent Jobs |
| 正規形式 | AIGateway のメッセージスキーマ | セマンティックアイテムを ChatML にプロジェクション |
| モデルが見る経路 | ステートフル Responses API | `modelVisibleTrajectory` プロジェクション |
| 圧縮 | AIGateway の圧縮が古いメッセージを置き換える | 圧縮されない（Job は再試行予算で境界付けられる）|

この 2 つは混ざりません。会話のメッセージは AIGateway のものであり、Job の軌跡は Job のものです。Job は起床イベント（[Background Agent Jobs](../background-agent-jobs/) を参照）を通じて結果を所有会話に報告します。会話のメッセージストアに書き込むわけではありません。

## このガイドがそうでないもの

ChatML 仕様ではありません。正規の ChatML 形式は標準であり、Ankole の読み取り時プロジェクションはその形状を保つもので、再定義しません。軌跡を読む消費者向け API でもありません。Console のルート（`/ai-gateway/conversations/:id/messages`、`/background-agent-jobs/:id`）はオペレーターサーフェスであり、[Console API reference](../console-api/) に文書化されています。そして保存ページの代わりでもありません。これは両方にまたがる形式レベルの見方です。

## 次のステップ

- 会話メッセージストアについては、[AIGateway](../ai-gateway/) を読んでください。
- Job 軌跡ストアについては、[Background Agent Jobs](../background-agent-jobs/) を読んでください。
- 圧縮（古いメッセージを置き換える）については、[Context compression](../context-compression-and-caching/) を読んでください。
- これらを読み取る Console ルートについては、[Console API reference](../console-api/) を読んでください。
