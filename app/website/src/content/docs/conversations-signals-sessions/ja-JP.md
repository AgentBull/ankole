---
title: 会話、シグナル、実行セッション
description: Ankole の設計とコスト、およびソースを確認した deepseek-harness、pi durable、qm の比較。
section: Developer guide
order: 100.5
---

Ankole は組織のために Agent を動かします。仕事は発言、時刻、外部イベント、タスク完了から始まります。責任を持つ Principal と、プロセス再起動後の復旧が必要です。

3 種類の事実を別のコンポーネントが所有します。**会話**は参加者の発言を保存し、**シグナル**は仕事を起こし、**実行セッション**は仕事を実行します。AIGateway はモデル状態を保存し、Delivery は外部送信の意図と結果を記録します。

## 4 つの設計上の選択

### 発言と作業を別に記録する

会話の記録には参加者が見られる発言が入り、作業ログにはモデル呼び出しとツール結果が入ります。会話に参加する各 Agent は独自の実行セッションとモデル状態を持ち、その作業は全参加者に見えます。実行セッションは複数の会話をまたぎません。

対話型および人間がトリガーしたターン（人間の発言で起動された `may_intervene` 介入ターンを含み、Agent の発言が他の Agent を起こすことはありません）は、**`Human ∩ Agent` の権限積集合**（`%Ankole.AuthZ.Actor{principal: agent, interactive_principal: human}`）で実行されます。対話する人間を伴わない自律的な非人間ターン（`cron`、`webhook`、バックグラウンドサービストリガー）は Agent 自身の権限で実行されます。可視範囲は会話に従い、実行権限はそのターンの `AuthZ.Actor` に従います。

### すべての刺激を Signals で受け付ける

発言、時刻、外部イベント、タスク完了は同じ受付 owner を使います。永続化、重複排除、帰属と認可、宛先解決を行います。

signal は実行セッションを直接指定できます。指定がなければ、参加関係または Signal Routing Rule が宛先を選びます。会話ホストのアダプターは発言を観測し、返信を配送します。イベントソースのアダプターは signal だけを生成します。新しい出所に別の受付機構は不要です。

### 定時作業には独立した実行セッションを使う

cron 規則は安定した `cron:<schedule_id>` 実行セッションを使い、バックグラウンドタスクも独自の実行セッションを持ちます。結果を会話に発言できます。会話の次のターンはその発言を読み込み、他の実行セッションのモデル呼び出しやツール結果は取り込みません。

### モデル状態の owner を 1 つにする

AIGateway は内部 Agent と外部クライアントに、有状態の Responses 呼び出しと hosted tools を提供します。ランタイムは入力、ツール、継続、圧縮を決めます。プラットフォームはモデル状態を保存し、その機構を実行します。

AIGateway conversation はモデル状態を指し、参加者の共有会話とは別です。Agent の履歴をランタイムに移すと、モデル状態を管理する 2 つ目の実装が必要になります。

## ソースを確認した比較

下表は **2026-10-14** に再確認したリポジトリのスナップショットです。リンクは確認した commit に固定されています。

| プロジェクト | 確認 commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 観点 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 記録モデル | 追記専用 `SessionEvent` ログからモデル履歴を導出。[ソース][D-session] | 不変 entries と task・文書の更新を原子的にコミット。[仕様][P-spec] | PostgreSQL `session_entries`。Slack と Web UI は同じ履歴を表示。[保存][Q-session]、[設計][Q-spec] | 会話の発言とモデル作業ログを分離 |
| 共有コンテキスト | Agent / Session 履歴とプラグイン定義の投影。[ソース][D-session] | ホストがメッセージ型とアプリ方針を定義。[ソース][P-guide] | 履歴はターンの受衆全員に見える必要がある。[ソース][Q-audience] | 会話内の Agent ごとに実行セッション。受衆は共有、モデル状態は独立、認可はターン単位 |
| 入力 | Agent 入力、定時 follow-up、別の webhook ランタイム。[定時][D-schedule]、[webhook][D-webhook] | Submission と永続 inbox。[ソース][P-guide] | cron、webhook、loop に別の機構。SPEC は loop の独立実装を批判。[ソース][Q-spec] | 全出所に同じ永続 signal 受付契約 |
| 定時と外部トリガー | 永続リマインダーは元の Session へ。webhook にキュー、再試行、再起動時再送、組み込み重複排除はない。[定時][D-schedule]、[webhook][D-webhook] | パッケージは submission / task API、外部トリガーはホストが提供。[ソース][P-guide] | cron の発火ごとに `cron:<id>:fire:<hash>`。[ソース][Q-cron] | 安定した cron 実行セッション。外部 signal を永続受付し、結果を対象会話に発言 |
| 外部配送 | 定時配送は元の Session 内。[ソース][D-schedule] | 外部チャネルはホストアプリが提供。[ソース][P-guide] | 永続配送記録と期限切れ処理。[ソース][Q-delivery] | 会話ホストのアダプター。上限付き再試行、失敗・期限切れ・結果不明の状態 |
| 保存と並行処理 | ローカル JSONL。Session ごとに 1 書き手を OS ロックで保護。[ソース][D-store] | Memory、SQLite、JSONL、Durable Object。1 プロセスが所有し、プロセス間ロックはない。[ソース][P-guide] | PostgreSQL。現在のコードは `session_entries` のみ読み書き。[ソース][Q-session] | PostgreSQL が正本。テナント分離。実行開始ごとに認可確認 |
| モデルコンテキスト | Session ログから導出。[ソース][D-session] | コミット済み entries から構成。[仕様][P-spec] | 受衆で絞った履歴から構成。[ソース][Q-audience] | AIGateway が保存・継続し、ランタイムが入力を決定 |

qm の SPEC は設計用語として「tape」を残していますが、`session_entries` への切り替えと後続の旧テーブル削除を記録しています。比較は現在のコードに基づき、以前の二重書き込み構造を現状として扱いません。[ソース][Q-spec]

## コストと受け入れる制限

- **概念とコードが増える。** 会話、signal、実行セッション、配送、モデル状態にそれぞれ owner が必要です。
- **2 つの記録を調べる。** 診断には会話の発言と実行セッションの作業ログが必要になる場合があります。
- **共有作業はグループに結果を開示する。** そのターンの権限で取得したデータは会話の共有コンテキストに入ります。ツール呼び出し権限（`agent:<uid>:tool:<tool_name>` の `invoke` アクションおよび `context.request.args`）と Pod 操作は、現在のターンの `AuthZ.Actor` に対して評価されます。一方、qm は受衆に応じて履歴を絞ります。[qm ソース][Q-audience]
- **配置が重い。** PostgreSQL トランザクションとコントロールプレーンは、ローカルファイルの harness より遅延と運用作業を増やします。
- **途中のテキストは永続化しない。** クラッシュで未完成のテキストが失われます。復旧ではモデル呼び出しを繰り返す場合があり、記録済みツール結果は再利用します。結果不明の操作は無条件に繰り返しません。外部副作用に exactly-once 保証はありません。pi durable は保存コミット後に進捗を公開します。[ソース][P-guide]
- **プラットフォームの制約がある。** 有状態リクエストには保存項目を損失なく再生できる wire が必要です。
- **単一の受付契約。** 全 producer とアダプターが同じ Signals 受付契約に従う必要があります。
- **cron 履歴が増える。** 安定した実行セッションは履歴を保持し、圧縮が必要です。qm は発火ごとに新しい実行セッションを作ります。[ソース][Q-cron]

## 別の方法が適する場面

- 個人開発者がローカルで 1 つの Agent と作業するなら、deepseek-harness や pi の配置は簡単です。
- 再開可能な Agent loop をアプリに埋め込むなら、pi durable のランタイム境界は小さくなります。
- Slack を中心に、モデル視点の履歴を基準とするチームアシスタントなら、qm の構造は直接的です。

発言から作業への流れは[アーキテクチャ](../architecture/)、用語は[クイックスタート](../quickstart/#terminology)を参照してください。

[D-session]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/core/session/README.md
[D-store]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/session/session-persistence-jsonl/README.md
[D-schedule]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/schedule/schedule/README.md
[D-webhook]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/experimental/webhook/README.md
[P-guide]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/README.md
[P-spec]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/docs/spec.md
[Q-session]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/sessions/postgres-session-store.ts
[Q-audience]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/resolution/context-filter.ts
[Q-cron]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/cron/scheduler.ts
[Q-delivery]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/delivery/delivery-store.ts
[Q-spec]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/docs/SPEC.md
