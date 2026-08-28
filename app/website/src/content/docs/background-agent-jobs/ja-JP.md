---
title: Background Agent Jobs
description: worker の損失を生き延びる永続的で再開可能な作業 — Job ステートマシン、入力待ち、owner の wakeup、Actor Runtime との境界。
section: Developer guide
order: 105
---

Background Agent Job は、どの 1 つの worker よりも長生きすることを意図した作業単位です。agent は、自分の turn の中でインラインで実行するには長すぎる、ステップが多すぎる、または分離が強すぎる作業のために 1 つを spawn します。その後、Job は自分自身のスケジュールで実行、入力待ちの一時停止、失敗、または完了を行い、開始した agent は owner と話せる状態を保ちます。このページでは、そのライフサイクルを `Ankole.BackgroundAgentJobs` の実際のコードに照らして説明します。

最初に決定的な性質を述べます。Job は永続的な作業であり、子プロセスではありません。その状態は PostgreSQL に保存され、すべての遷移はフェンスされ監査され、owner が知るべき方法でステータスが変わると、Job は通常の signal が使うのと同じ actor-event キューを通じて、owner の session に wakeup イベントを追加します。

## Actor Runtime との境界

session turn と background job は異なる形状の作業であり、ランタイムはそれらを分離します。Actor Runtime はライブでフェンスされた turn（session を wake し、1 つのモデルループを実行し、commit する）を所有します。Background Agent Job は、turn が委任する永続的で再開可能な作業を所有します。ハンドオフは明示的です。Job は `owner_session_id`、`source_actor_event_id`、`source_tool_call_id` を保持するため、spawn した turn から Job へのリンクと、その逆のリンクは常に再構築可能です。

これが実際に意味すること：Job は第二の session でも、agent に対する競合する主張でもありません。それは owner session が依頼した作業であり、独自のステートマシン、独自の再試行予算、独自の報告方法を持ちます。

## Job ステートマシン

Job は 6 つのステータスを遷移し、遷移は固定されたテーブルで制約されます。

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — 受け入れ済み。まだ agent の実行スロットを要求していない。
- **`running`** — agent の実行スロットの 1 つを占有中（agent ごとに最大 3 つ）。
- **`waiting_on_user`** — 人の入力のために一時停止中。実行スロットを解放し、後の turn が再開する。
- **`succeeded`**、**`failed`**、**`stopped`** — 終端。終端の Job にはライブな実行がない。

すべての遷移は `transition_allowed?/2` を通過するため、`queued` の Job は `running` を経由せずに `succeeded` へ跳ぶことはできず、終端の Job はまったく動きません。このテーブルがコントラクトであり、アプリケーションコードの何もそれを迂回してはなりません。

## Wakeup: owner への報告

Job が owner が知るべきステータスに到達すると、ライフサイクルは遷移をコミットし、同じトランザクションで owner の session に wakeup イベントを追加します。3 つのステータスが wakeup を生成します。

| Job ステータス | Wakeup イベントタイプ |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

wakeup は通常の actor イベントです。他の signal と同じキュー、同じフェンス、同じ session コントローラーを使い、`owner_session_id` 宛てで、Job の `reply_route`（その binding、channel、thread）を通じてルーティングされます。owner session はポーリングしません。報告すべきことがあるときだけ正確に wake されます。`queued` または `running` への遷移は wakeup を生成しません。これらは owner が行動する必要のあることではないからです。

wakeup イベントの source id は Job、ステータス、試行番号をエンコードするため、再開された Job の後の wakeup が以前のものと混同されることはありません。

完了 wakeup はサイズが制限された結果概要を保持します。保存された最終応答が概要の上限を超える場合、owner Agent は `result_offset: 0` を指定して `show_background_job_details` を呼び出します。返された `result.next_offset` を次の呼び出しに渡し、値が `null` になるまで続けます。UTF-8 安全な各セグメントを順番に連結すると、元の応答を正確に復元できます。これにより、別の Job 操作を追加せずに、wakeup と各読み取りのサイズを制限できます。

## 再開と入力待ち

`waiting_on_user` は、スロットを保持せずに Job を生かしておく一時停止です。Job が人の決定を必要とするとき、`waiting_on_user` に遷移します。最新ステータスの投影は、エラーコード `request_user_input` と保留中の tool call を持つ `interrupted` を記録するため、owner の次の turn には再開する正確な場所があります。人が回答すると、Job は `running` に戻って続行します。

Job は自分の一時停止ではなく、前の Job から続行することもできます。`continued_from_job_id` と `workspace_owner_job_id` がそのチェーンを記録します。これが、長い作業がスレッドや workspace を失わずに前方へ引き継がれる方法です。

## worker の障害を越えたリカバリ

Job の状態は永続的であるため、worker の損失はデータ損失イベントではなく、リカバリ可能なイベントです。ランタイムは Job に有界な再試行予算（最大 5 回の実行試行、最大 5 回の連続 turn 失敗）を与え、試行がクリーンに開始されない場合、`requeue_unstarted_attempt` は試行カウンターを減らして Job を `queued` に戻し、最初の試行では `started_at` をクリアして新しい開始のように見せます。

2 つの claim パスが 2 つのリカバリ形状をカバーします。

- **`claim_attempt_in_tx`** — 新しい実行試行のために Job を claim する。
- **`claim_continuation_in_tx`** — 一時停止の後に続行するために Job を claim する。

どちらも、その固定された順序で、まず agent のスロットロックを取り、次に `FOR UPDATE` の下で Job 行を取ります。したがって、同じ agent に対する並行ディスパッチャーは毎回同じように解決します。予算を超えた再試行は `failed` になり、キャンセルされた Job は `stopped` になります。試行間の再試行遅延は 30 秒に制限されているため、一時的に失敗した Job が provider を激しく叩くことはありません。

AIGateway のクォータ枯渇に既知の将来のリカバリ時刻がある場合、Job は `queued` に戻り、Worker の割り当てを解放し、その時刻のディスパッチをスケジュールします。取得済みの試行は消費されたままなので、繰り返されるクォータ失敗は 5 回の試行予算内に留まります。リカバリ時刻が古いか欠落している場合は、即時ディスパッチではなく、通常の有界 Job 再試行パスを使います。

## ディスパッチと agent のプラグイン

Job はオプションの workspace テンプレートを 1 つ保持します。最初の実際の execution admission は、provider と model の binding、および Agent Plugin と Skill の選択を同じトランザクションで記録します。再試行と再開は、その固定された選択と agent の現在の有効セットとの積集合を使います。選択済みの capability を無効にすると削除され、再度有効にすると復元されますが、admission 時に選択されなかった capability を後から追加することはできません。credential と変更可能な Skill content は、引き続き現在の owner から読み取ります。ディスパッチパス（`BackgroundAgentJobDispatch.process`）は actor イベントから Job を解決し、turn ランタイムに渡し、steer イベントを別々に扱うため、session へのライブ配信が Job への steer と誤認されません。すべてのモデル turn は記録済みの binding で AIGateway を通ります。その provider が複数の credential を持つ場合、その選択、affinity、refresh、retry は AIGateway が所有します。Job はアカウントフィールドもアカウント並行スロットも持ちません。

Background Agent Job は、メイン Agent と同じ Ankole `skill_view` loader を使用します。通常の互換 Skill は Job の Skill index に入ります。`brain-recall-only: true` を宣言した Skill は index に入らず、Brain から発見できます。`get_page` が対応する発見レコードに一致すると、`skill_view` に委譲します。loader は `SKILL.md` または reference file を読むたびに、現在の Agent Plugin と Skill の実効状態を control plane に確認します。そのため、実行中の Job も、無効化された Skill を読み続けることはできません。この経路は Codex native Skill discovery、`.agents/skills`、`skills/list` に依存しません。

Job が初めて workspace を初期化するとき、ランナーはプロジェクトの `AGENTS.md` を組み立てます。オプションの workspace テンプレートが最初に来て、その後にレンダリングされた Job context（agent の SOUL と MISSION、実行の事実）が続きます。共有の `app/library/templates/AGENT_JOB.md` は拡張ポイントのままですが、同梱のファイルは空なので、ランナーは Job Guidance セクションを省略します。Codex プロジェクト設定は、ネイティブ subagent の待ち最小時間を 1 分、デフォルトを 2 分に設定します。最大時間は設定しないため、Codex はデフォルトを維持します。これにより、空の待ち時間の後の繰り返しのモデル turn が減ります。これは [openai/codex#35259](https://github.com/openai/codex/issues/35259) で追跡されています。再開されたスレッドは既存の `AGENTS.md` を保持します。

## 運用者向けの表面

3 つの Console スコープのルートが、運用者が必要なものをカバーします。

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/background-agent-jobs` | Job を一覧表示 |
| `GET` | `/background-agent-jobs/:job_id` | 1 つの Job を読み取る |
| `POST` | `/background-agent-jobs/:job_id/cancel` | Job をキャンセル |

キャンセルは Job を `stopped` に導きます。実行中の turn の下からライブの worker を引き抜くことはありません。turn は、すべての worker 書き込みが通過するのと同じ activation と revision チェックでフェンスされ、自分で完了するか失敗します。

## Background Agent Jobs がそうでないもの

Job は自由形式のバックグラウンドプロセスではありません。固定の遷移テーブル、有界の再試行予算、報告先の単一の owner session を持つステートマシンです。権限境界の外で作業を実行する手段でもありません。Job はその agent として、同じプラグインと Skill の下で実行されます。また、Actor Runtime の代替でもありません。2 つは actor-event キューとフェンス機構を共有しますが、Job は再開可能な作業を所有し、ランタイムはライブの turn を所有します。この境界は意図的であり、越えるには文書化された遷移を経由し、他方のレイヤーの内部に手を伸ばすのではありません。

## 次のステップ

- Job が spawn され、報告先となるライブの turn については、[Actor Runtime](../actor-runtime/)ページを参照してください。
- Job の実行が走らせるモデル turn については、[AIGateway API](../ai-gateway/)を参照してください。
- Job の wakeup が通常の signal として owner に届く仕組みについては、[SignalsGateway](../signals-gateway/)ページを参照してください。
