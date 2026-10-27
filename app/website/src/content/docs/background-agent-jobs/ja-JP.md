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

すべての状態変更は `transition_allowed?/2` を通るため、`queued` から `running` を飛ばして直接 `succeeded` へ遷移するようなことはできず、一度終端状態に入った Job が再び動き出すこともありません。この遷移テーブル自体がシステムの契約であり、アプリケーションコードからバイパスすることは禁止されています。

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

`waiting_on_user` は、実行スロットを占有し続けることなく Job を生かしたまま待機させるための一時停止状態です。人間の意思決定が必要になると Job は `waiting_on_user` へ遷移し、最新ステータスの投影レコードにはエラーコード `request_user_input` と保留中のツール呼び出しを伴う `interrupted` 状態が記録されます。これにより、owner 側の後続 Turn はどこから再開すべきかを正確に把握でき、人間からの回答が届いた時点で Job を `running` に戻して処理を継続できます。

また、一時停止からの再開だけでなく、完了した過去の Job を引き継いで新しい Job を継続実行することも可能です。その連鎖は `continued_from_job_id` と `workspace_owner_job_id` に記録されるため、スレッド履歴や workspace の成果物を失わずに長期タスクを段階的に進められます。

## worker の障害を越えたリカバリ

Job の状態は PostgreSQL に永続化されているため、途中で Worker が失われてもデータ損失にはならず、リカバリ可能な事象として処理されます。ランタイムは各 Job に上限付きのリトライ予算（最大 5 回の実行試行、最大 5 回の連続 Turn 失敗）を与えます。もし試行が正常に立ち上がる前に中断された場合は、`requeue_unstarted_attempt` が試行カウンタを戻したうえで Job を `queued` に戻します（初回試行であれば `started_at` もクリアし、未開始の状態に整えます）。

Job の実行権確保（claim）には、用途に応じた 2 つのトランザクションパスがあります。

- **`claim_attempt_in_tx`** — 新しい実行試行を開始するために Job を確保します。
- **`claim_continuation_in_tx`** — 一時停止後の処理を再開するために Job を確保します。

どちらのパスでも、必ず「まず Agent のスロットロックを取得し、次に `FOR UPDATE` で Job レコードを取得する」という固定順序でロックを取ります。そのため、同じ Agent に対して複数のディスパッチャーが並行に動いても競合せず、常に一貫した順序で解決されます。リトライ予算を使い切った Job は `failed` に、キャンセルされた Job は `stopped` に遷移します。なお、試行間のリトライ待機時間は最大 30 秒に抑えられており、一時的なエラーで上流 provider に過剰な負荷をかけないようになっています。

AIGateway のクォータ上限に達し、かつ次回の回復予定時刻が判明している場合、Job はいったん `queued` に戻って Worker の割り当てを解放し、その回復時刻に合わせて再ディスパッチを予約します。その際、すでに消費した試行回数はそのまま維持されるため、クォータ枯渇が繰り返されても 5 回の試行予算の範囲内に収まります。回復時刻が過去になっている場合や不明な場合は、即時ディスパッチではなく通常の上限付きリトライ経路に入ります。

## ディスパッチと agent のプラグイン

各 Job は任意の workspace テンプレートを 1 つ保持できます。初回の実行受け入れ（execution admission）時に、使用する provider・モデルの binding と、Agent Plugin および Skill の選択セットが同一トランザクションで記録・固定されます。以降のリトライや再開では、「その初回固定セット」と「現時点で Agent に有効なセット」の積集合（共通部分）が適用されます。つまり、途中で無効化された capability は使えなくなり、再度有効化すれば復活しますが、初回 admission 時に含まれていなかった capability が後から追加されることはありません。なお、認証情報と更新可能な Skill 本体については、実行時点での最新の管理元から読み取られます。`Sessions.CodexJob` はその kernel Signal から Job の試行を受け入れ、steer イベントを通常のセッション配信とは区別して処理するため、会話セッションへの通常のメッセージ配信が誤って Job への steer として扱われることはありません。すべてのモデル Turn は記録済みの binding を使って AIGateway を経由し、provider が複数の認証情報を持つ場合の選択・アフィニティ・トークン更新・リトライはすべて AIGateway が管理します。

Skill の読み込みには、メイン Agent と共通の Ankole `skill_view` ローダーが使われます。互換性のある通常の Skill は Job の Skill インデックスに登録されますが、`brain-recall-only: true` が指定された Skill はインデックスには入らず、Brain 経由で検索・発見されます（対応する発見レコードに対して `get_page` を呼ぶと `skill_view` へ委譲されます）。ローダーは `SKILL.md` や参照ファイルを開くたびに control plane へ現在の Agent Plugin・Skill の実効状態を問い合わせるため、実行中の Job であっても無効化された Skill を読み続けることはできません。

Job が初めて workspace を初期化する際、ランナーはプロジェクトの `AGENTS.md` を組み立てます。先頭に任意の workspace テンプレートが配置され、続けてレンダリングされた Job コンテキスト（Agent の SOUL と MISSION、および実行メタデータ）が追記されます。また、Codex プロジェクト設定ではネイティブ subagent の最小待機時間を 1 分、既定待機時間を 2 分に設定します（最大待機時間は指定せず Codex の既定値を維持します）。これにより、[openai/codex#35259](https://github.com/openai/codex/issues/35259) で追跡されている「空の待機後にモデル Turn が繰り返される現象」を抑えています。再開されたスレッドでは、そのプロジェクトの `AGENTS.md` がそのまま再利用されます。

## 運用者向けの表面

運用者が利用する主な Console API ルートは次の 3 つです。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/background-agent-jobs` | Job の一覧を取得 |
| `GET` | `/background-agent-jobs/:job_id` | 特定の Job の詳細を取得 |
| `POST` | `/background-agent-jobs/:job_id/cancel` | Job をキャンセル |

キャンセルを実行すると Job は `stopped` に遷移し、実行中の処理に対して停止要求が送られます。後から遅延して届いた Worker の実行結果をコミットしてよいかどうかは、PostgreSQL 上の Job ステータス、attempt 識別子、および Turn リビジョンによって厳密に判定されます。

## Background Agent Jobs がそうでないもの

Background Agent Job は野放図に動くバックグラウンドプロセスではありません。固定の状態遷移テーブル、上限付きのリトライ予算、そして報告先となる単一の owner session を備えた厳格なステートマシンです。また、権限境界を抜け出すための仕組みでもなく、あくまでその Agent 自身として同じ Plugin・Skill 制約のもとで動作します。さらに Sessions を置き換えるものでもありません。両者は Signal キューとフェンス機構を共有しつつ、Job が「中断・再開可能な長時間作業」を担い、Sessions が「ライブの対話 Turn」を担うという明確な役割分担で成り立っています。

## 次のステップ

- Job の起動元であり報告先でもあるライブ Turn の仕組みについては、[Sessions](../sessions/) を参照してください。
- Job の実行中に呼び出されるモデル境界については、[AIGateway API](../ai-gateway/) を参照してください。
- Job の wakeup が通常の Signal として owner へ届く仕組みについては、[Signals](../signals/) を参照してください。
