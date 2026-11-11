---
title: Background Agent Jobs
description: Worker の障害や再起動をまたいで継続できる永続ジョブの仕組み。ステートマシン、入力待ち、owner への wakeup、Sessions との責務境界を説明します。
section: Developer guide
order: 105
---

Background Agent Job は、個々の Worker インスタンスの寿命を超えて継続できるよう設計された作業単位です。通常の会話 Turn の中でそのまま実行するには時間がかかりすぎる処理、ステップ数の多い処理、あるいは独立した作業環境が必要な処理に対して、Agent がバックグラウンドジョブを起動（spawn）します。起動された Job は独自のスケジュールで実行・入力待ちの一時停止・失敗・完了まで進み、その間も元の Agent はユーザーとの会話をブロックせず続けられます。このページでは、`Ankole.BackgroundAgentJobs` の実装に沿ってそのライフサイクルを解説します。

まず最も重要な性質として、Background Agent Job は単なる OS の子プロセスではなく**永続化された作業単位**です。状態はすべて PostgreSQL に保存され、あらゆる状態遷移がフェンスと監査の対象になります。そして owner が把握すべき状態変化が起きたときには、通常の Signal とまったく同じキューを通じて owner のセッションに wakeup イベントを届けます。

## Sessions との境界

通常のセッション Turn と Background Agent Job は作業の性質が異なるため、ランタイム上でも明確に分離されています。Sessions はライブのフェンス付き Turn（セッションを起動し、1 回のモデルループを回してコミットする処理）を担当し、Background Agent Job は Turn から委任された「中断・再開可能な長時間作業」を担当します。両者の受け渡しは明示的に記録され、Job レコードが `owner_session_id`、`source_signal_id`、`source_tool_call_id` を保持することで、「どの Turn がどの Job を起動したか」およびその逆の対応関係をいつでも完全にたどれます。

各 Job は同じ Agent に属する独立した `job:<id>` Session 上で動作し、進捗や完了を `owner_session_id` へ報告します。また、独自のステートマシン、リトライ予算、報告ルールを備えています。

## Job ステートマシン

Job は次の 6 つのステータス間を遷移します。許可される遷移経路は固定のテーブルで厳格に定義されています。

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — 受け付け完了状態。まだ Agent の実行スロットを確保していません。
- **`running`** — Agent の実行スロットを 1 つ占有して作業中（既定では Agent ごとに最大 3 スロット）。
- **`waiting_on_user`** — 人間の判断や追加入力を待つために一時停止中。実行スロットをいったん解放し、後続の Turn から再開されます。
- **`succeeded`**、**`failed`**、**`stopped`** — 終端状態。終端に達した Job には実行中の処理は残りません。

許可される状態遷移は `Ankole.BackgroundAgentJobs.Schemas.Job` の Ash ステートマシンが定義します。Worker が完了を報告できるのは `running` の Job だけですが、運用者の `external_complete` 操作は `queued`、`running`、`waiting_on_user` の Job を完了できます。終端状態から別の状態へは遷移できません。

## Wakeup: owner への報告

Job が owner に知らせるべきステータスへ到達すると、状態遷移のコミットと同一トランザクション内で owner のセッションへ wakeup イベントが追加されます。wakeup を発生させるのは次の 3 つのステータスです。

| Job ステータス | Wakeup イベントタイプ |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

wakeup イベントの実体は通常の Signal です。他の Signal と同じキュー、同じフェンス、同じセッションコントローラーを通って `owner_session_id` 宛てに届き、Job に記録された `reply_route`（binding、チャネル、スレッド）に従ってルーティングされます。そのため owner セッション側でポーリングを行う必要はなく、報告すべき変化が起きたときにだけ正確に起動されます（`queued` や `running` への遷移では owner 側の対応が不要なため、wakeup は生成されません）。

また、wakeup イベントの source ID には Job ID・ステータス・試行番号がエンコードされるため、一時停止から再開した後に発生する wakeup が過去の wakeup と取り違えられることはありません。

完了時の wakeup にはサイズ上限付きの結果サマリーが含まれます。保存された最終応答がこのサマリー上限を超える場合、owner Agent は `result_offset: 0` を指定して `show_background_job_details` を呼び出し、返された `result.next_offset` を次の呼び出しに渡して `null` になるまで順に読み進めます。UTF-8 文字境界を壊さずに分割された各セグメントを結合することで、元の全文を正確に復元できます。この仕組みにより、wakeup ペイロードや 1 回あたりの読み取りサイズを一定以下に抑えつつ、長大な永続結果も漏れなく参照できます。

## 再開と入力待ち

`waiting_on_user` は、実行スロットを占有し続けることなく Job を生かしたまま待機させるための一時停止状態です。人間の意思決定が必要になると Job は `waiting_on_user` へ遷移し、最新ステータスの投影レコードにはエラーコード `request_user_input` と保留中のツール呼び出しを伴う `interrupted` 状態が記録されます。これにより、owner 側の後続 Turn はどこから再開すべきかを正確に把握でき、人間からの回答が届いた時点で Job を `running` に戻して処理を継続できます。なお、`waiting_on_user` で `10` 分以上一時停止し、かつ直近のモデル呼び出しで報告された総トークン数が `128,000` 以上に達していた Job を再開する際は、`CodexJobSession` が冷えた巨大なコンテキストウィンドウを再送する代わりに上限付きの Workspace 再構築情報（`job.task`、永続 Workspace ファイル、上限付きの試行履歴、および引き継ぎ元のタスク・最終レポート）から新しいスレッドを開始し、新規スレッド開始時やコンパクション確定時にランタイム CLI の `contextId` をローテーションします。

また、一時停止からの再開だけでなく、完了した過去の Job を引き継いで新しい Job を継続実行することも可能です。その連鎖は `continued_from_job_id` と `workspace_owner_job_id` に記録されるため、スレッド履歴や workspace の成果物を失わずに長期タスクを段階的に進められます。

## worker の障害を越えたリカバリ

Worker が失われても、PostgreSQL が Job の状態を、永続 Home が workspace と Codex スレッドを保持します。各 Job の上限は実行失敗 5 回、スロットの確保 25 回、連続 Turn 失敗 5 回です。新しいスロットを確保すると `attempts` が増え、実行中の試行を引き継ぐだけなら増えません。インフラ障害で再試行する場合は `queued` に戻り、実行失敗回数は消費しませんが、スロット確保回数は維持します。

実行権の確保には次の 2 つのトランザクションパスを使います。

- **`claim_attempt_in_tx`** は `queued` の Job に新しい実行試行を確保します。
- **`claim_continuation_in_tx`** は入力後の継続実行を確保します。

どちらも Agent の実行枠をロックしてから Job レコードをロックします。再試行の上限に達すると `failed`、運用者がキャンセルすると `stopped` になります。

待機時間は `Ankole.Sessions.TurnErrorClassifier` が選びます。インフラ障害では 15、30、60、120、300 秒の順に待機し、実行失敗回数は消費しません。再試行可能な実行失敗や provider の容量不足では 60、600、1,800、3,600、7,200 秒の順に待機し、実行失敗回数を消費します。再試行できない拒否は直ちに失敗となります。

AIGateway が credential pool の枯渇と将来の回復時刻を返した場合、Job は `queued` に戻り、Worker の割り当てを解放して、その時刻に再ディスパッチします。実行失敗回数は消費しませんが、確保済みのスロットは 25 回の上限に数えます。回復時刻が不明または過去の場合は、通常の実行失敗の待機時間を使い、実行失敗回数を 1 回消費します。

## ディスパッチと agent のプラグイン

各 Job は任意の workspace テンプレートを 1 つ保持できます。初回の実行受け入れ（execution admission）時に、使用する provider・モデルの binding と、Agent Plugin および Skill の選択セットが同一トランザクションで記録・固定されます。以降のリトライや再開では、「その初回固定セット」と「現時点で Agent に有効なセット」の積集合（共通部分）が適用されます。つまり、途中で無効化された capability は使えなくなり、再度有効化すれば復活しますが、初回 admission 時に含まれていなかった capability が後から追加されることはありません。なお、認証情報と更新可能な Skill 本体については、実行時点での最新の管理元から読み取られます。`Sessions.CodexJob` はその kernel Signal から Job の試行を受け入れ、steer イベントを通常のセッション配信とは区別して処理するため、会話セッションへの通常のメッセージ配信が誤って Job への steer として扱われることはありません。すべてのモデル Turn は記録済みの binding を使って AIGateway を経由し、provider が複数の認証情報を持つ場合の選択・アフィニティ・トークン更新・リトライはすべて AIGateway が管理します。

Background Agent Job はメイン Agent と同じく `Ankole.AIAgent.Library` を背後とする動的な `skill_view` ローダーを使います。各実行の前に、Worker は Job に固定された Skill 選択セットと `Ankole.AIAgent.Library` 上でその Agent に現在有効化されている Skill セットおよび `ankole-runtime` フィルタの積集合を計算し、許可された各パッケージ（同梱ファイル、スクリプト、MCP 宣言を含む）を `/workspace/.ankole/turn-skills/<signal-id>/<skill-name>/` に配置します。`skill_view` が呼ばれるたびに、コントロールプレーンは現在の有効状態を確認したうえで `Ankole.AIAgent.Library` から Skill マニフェストやパッケージ内の相対パスファイルを読み取り、Agent ごとの有効な Skill lesson を付加します。

Worker は Turn の開始時と再開時に、`Ankole.AIAgent.Library.Contracts` が合成した Agent の有効契約全文を `$CODEX_HOME/AGENTS.md` と `~/AGENTS.md` に、視覚仕様を `~/DESIGN.md` に反映します。プロジェクト内の指示はワークスペーステンプレートやリポジトリが管理します。Job の実行情報と Skill 一覧は developer instructions で渡します。Codex の子 Agent の待機時間は最短 1 分、既定 10 分です。

## 運用者向けの表面

`/api/v2` 配下の Console API ルートで Job の一覧・詳細確認、Turn 履歴、ヘルス状態、およびライフサイクル制御を行えます。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/v2/background-agent-jobs` | Job の一覧を取得 |
| `GET` | `/api/v2/background-agent-jobs/:id` | 特定の Job の詳細を取得 |
| `GET` | `/api/v2/background-agent-jobs/health` | Job サブシステムのヘルス状態を取得 |
| `GET` | `/api/v2/background-agent-jobs/:job_id/turns` | 特定の Job の Turn 履歴を取得 |
| `POST` | `/api/v2/background-agent-jobs/:id/cancel` | Job をキャンセル |
| `POST` | `/api/v2/background-agent-jobs/:id/complete` | Job を完了状態にする |

キャンセルを実行すると Job は `stopped` に遷移し、実行中の処理に対して停止要求が送られます。後から遅延して届いた Worker の実行結果をコミットしてよいかどうかは、PostgreSQL 上の Job ステータス、attempt 識別子、および Turn リビジョンによって厳密に判定されます。

## Background Agent Jobs がそうでないもの

Background Agent Job は野放図に動くバックグラウンドプロセスではありません。固定の状態遷移テーブル、上限付きのリトライ予算、そして報告先となる単一の owner session を備えた厳格なステートマシンです。また、権限境界を抜け出すための仕組みでもなく、あくまでその Agent 自身として同じ Plugin・Skill 制約のもとで動作します。さらに Sessions を置き換えるものでもありません。両者は Signal キューとフェンス機構を共有しつつ、Job が「中断・再開可能な長時間作業」を担い、Sessions が「ライブの対話 Turn」を担うという明確な役割分担で成り立っています。

## 次のステップ

- Job の起動元であり報告先でもあるライブ Turn の仕組みについては、[Sessions](../sessions/) を参照してください。
- Job の実行中に呼び出されるモデル境界については、[AIGateway API](../ai-gateway/) を参照してください。
- Job の wakeup が通常の Signal として owner へ届く仕組みについては、[Signals](../signals/) を参照してください。
