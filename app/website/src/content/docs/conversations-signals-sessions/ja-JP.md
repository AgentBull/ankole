---
title: 会話、シグナル、実行セッション
description: Ankole における会話・シグナル・実行セッションの設計判断とトレードオフ、およびソースコードを確認したうえでの deepseek-harness、pi durable、qm との比較を説明します。
section: Developer guide
order: 100.5
---

Ankole は組織の業務を担う Agent を稼働させる基盤です。仕事はチャットでの発言だけでなく、スケジュール時刻の到来、外部システムのイベント、バックグラウンドタスクの完了など多様なきっかけから始まり、常に「誰の権限で動くか（Principal）」と「プロセス再起動後にどう復旧するか」が求められます。

そのため Ankole では、性質の異なる 3 つの事実を別々のコンポーネントで管理しています。**会話（Conversations）**は参加者間の発言履歴を保存し、**シグナル（Signals）**は作業のきっかけを受け付け、**実行セッション（Sessions）**は実際の作業を実行します。さらにモデル状態は AIGateway が保持し、外部チャネルへの送信意図と結果は Delivery が記録します。

## 4 つの設計上の選択

### 発言と作業を別に記録する

会話レコードには参加者全員に見える発言だけが入り、モデル呼び出しやツール実行結果などの内部作業ログは別の記録として保持されます。会話に参加する各 Agent はその会話専用の実行セッションとモデル状態を持ち、その応答結果は参加者全員に共有されます。1 つの実行セッションが複数の会話をまたぐことはありません。

各 Agent は会話ごとに独立した Session を持ち、その出力は会話の参加者に共有されます。対話、人間の発言で起動する `may_intervene`、スケジュール、サービスによる起動のいずれも、リソースへのアクセスは実行する Agent の権限で判定します。Agent の発言が他の Agent を起動することはありません。人間の在籍状態と指示のバージョンは委任の有効性を確認するために引き続き検査されますが、リソース権限との積集合は取りません。

### すべての刺激を Signals で受け付ける

人間の発言、スケジュール時刻、外部 Webhook イベント、タスク完了通知はいずれも共通の受付基盤（Signals）を通ります。永続化、重複排除、帰属情報と認可の記録、および宛先解決が一箇所に集約されています。

Signal には宛先の実行セッションを直接指定でき、指定がない場合は会話への参加関係または Signal Routing Rule から宛先が決まります。チャット連携アダプターは発言の取り込みと返信の配送を担い、イベントソース型アダプターは Signal の生成だけを行います。新しいイベント発生元を追加する際も、別の独自キューを作る必要はありません。

### 定時作業には独立した実行セッションを使う

cron スケジュールは不変の `cron:<schedule_id>` 実行セッションを使用し、バックグラウンドタスクもそれぞれ独立した実行セッションを持ちます。作業が完了したら、結果だけを目的の会話に発言として投稿できます。会話側で次に始まるターンはその投稿された発言だけを読み込み、別セッション内部のモデル呼び出し履歴やツール結果までは取り込みません。

### モデル状態の owner を 1 つにする

AIGateway は内部の Agent と外部 API クライアントの双方に対して、ステートフルな Responses 呼び出しと hosted tools を提供します。どの入力・ツールを渡し、いつ継続・圧縮を行うかという方針はランタイム側が決め、モデル状態の永続化と実行メカニズムはプラットフォーム（AIGateway）側が一元管理します。

なお、AIGateway 上の `conversation` はあくまでモデルの継続状態を指す単位であり、人間と Agent が共有する会話（`Ankole.Conversations`）とは別物です。もし Agent のモデル履歴管理をランタイム側にも持たせると、モデル状態の管理実装が二重になってしまいます。

## ソースを確認した比較

以下の比較表は **2026-10-14** 時点で各リポジトリのソースコードを確認したスナップショットであり、リンク先は確認対象の commit に固定されています。

| プロジェクト | 確認 commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 観点 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 記録モデル | 追記専用の `SessionEvent` ログからモデル履歴を導出。[ソース][D-session] | 不変の entries と task・文書の更新を原子的にコミット。[仕様][P-spec] | PostgreSQL の `session_entries`。Slack と Web UI で同じ履歴を表示。[保存][Q-session]、[設計][Q-spec] | 会話の発言履歴とモデルの作業ログを分離 |
| 共有コンテキスト | Agent / Session 履歴とプラグイン定義の投影。[ソース][D-session] | ホストアプリ側でメッセージ型と運用方針を定義。[ソース][P-guide] | ターンの閲覧対象者（audience）全員に見える履歴のみを含める。[ソース][Q-audience] | 会話内の Agent ごとに独立した実行セッション。発言は共有、モデル状態は独立、認可はターン単位 |
| 入力受付 | Agent 入力、定時 follow-up、および別建ての webhook ランタイム。[定時][D-schedule]、[webhook][D-webhook] | Submission と永続 inbox。[ソース][P-guide] | cron・webhook・loop で別々の機構（SPEC 内でも loop の独立実装を課題視）。[ソース][Q-spec] | すべての発生元で共通の永続 Signal 受付契約を使用 |
| 定時実行と外部トリガー | 永続リマインダーは元の Session へ投入。webhook にはキュー・再試行・再起動時再送・組み込み重複排除なし。[定時][D-schedule]、[webhook][D-webhook] | パッケージは submission / task API を提供し、外部トリガーはホスト側が実装。[ソース][P-guide] | cron の発火ごとに `cron:<id>:fire:<hash>` を作成。[ソース][Q-cron] | 不変の cron 実行セッションを使用。外部 Signal も永続受付し、結果だけを対象会話へ投稿 |
| 外部配送 | 定時配送は元の Session 内で処理。[ソース][D-schedule] | 外部チャネル連携はホストアプリ側が提供。[ソース][P-guide] | 永続配送レコードと有効期限切れ処理。[ソース][Q-delivery] | 会話ホストアダプターによる配送。回数上限付き再試行と失敗・期限切れ・結果不明の状態管理 |
| 保存と並行制御 | ローカル JSONL。Session ごとに単一 writer を OS ロックで保護。[ソース][D-store] | Memory、SQLite、JSONL、Durable Object。単一プロセス所有でプロセス間ロックはなし。[ソース][P-guide] | PostgreSQL。現行コードは `session_entries` のみを読み書き。[ソース][Q-session] | PostgreSQL が正本。テナント分離と実行開始ごとの認可チェック |
| モデルコンテキスト | Session ログから導出。[ソース][D-session] | コミット済み entries から構成。[仕様][P-spec] | 閲覧対象者でフィルタした履歴から構成。[ソース][Q-audience] | AIGateway が保存・継続し、ランタイムが各ターンの入力を決定 |

なお、qm の SPEC には設計用語として「tape」という表現が残っていますが、`session_entries` への移行と旧テーブルの削除が明記されています。そのため上の比較表は現行コードにもとづいて整理しており、過去の二重書き込み構造は対象としていません。[ソース][Q-spec]

## コストと受け入れる制限

この分離設計には明確なコストとトレードオフがあります。

- **概念とコード量が増える:** 会話、Signal、実行セッション、外部配送、モデル状態のそれぞれに専用の管理モジュールが必要になります。
- **調査時に見るべき記録が 2 箇所に分かれる:** トラブルシューティングでは、会話側の発言履歴と実行セッション側の作業ログの両方を照らし合わせる必要があります。
- **共有会話の応答結果は参加者に公開されます。** 実行 Agent が取得して応答に含めた情報は会話の共有コンテキストに入ります。利用可能なツールはそのカタログで決まり、ツール内部のリソース操作は Agent として認可されます。人間の指示の有効性は別に確認します。qm は閲覧対象者に応じて履歴をフィルタリングします。[qm ソース][Q-audience]
- **インフラ構成が重くなる:** PostgreSQL トランザクションと control plane を前提とするため、ローカルファイル完結型のハーネスに比べるとレイテンシと運用コストが増えます。
- **ストリーミング途中の未完成テキストは永続化されない:** クラッシュ時には生成途中のテキストは破棄されます。復旧時にはモデル呼び出しを再実行することがありますが、記録済みのツール結果は再利用され、結果不明の呼び出しを無条件に再実行することはありません。外部システムへの副作用に対する厳密な 1 回実行（exactly-once）保証はありません（一方、pi durable はストレージコミット後に進捗を公開します。[ソース][P-guide]）。
- **通信プロトコル上の制約がある:** ステートフルなリクエストを継続するには、保存済みアイテムを欠落なく再生できる通信フォーマットが必要です。
- **単一の受付契約への準拠が必要:** すべてのイベント生成元とアダプターが Signals の受付契約に従う必要があります。
- **cron セッションの履歴が蓄積する:** 固定の実行セッションを使い続けるため履歴が伸び、定期的なコンパクションが必要になります（qm の場合は発火のたびに毎回新しい実行セッションを作成します。[ソース][Q-cron]）。

## 別の方法が適する場面

- 個人開発者が自分のマシン上で 1 つの Agent を手軽に動かしたいなら、deepseek-harness や pi の方がシンプルに構築できます。
- 既存のアプリケーション内部に再開可能な Agent ループをライブラリとして組み込みたいなら、ランタイム境界が小さい pi durable が適しています。
- Slack を主戦場とし、モデル視点の単一履歴を中心に据えたチームアシスタントを作りたいなら、qm の構造の方がストレートです。

発言から作業完了までの全体の流れについては[アーキテクチャ](../architecture/)を、各用語の定義については[クイックスタート](../quickstart/#terminology)を参照してください。

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
