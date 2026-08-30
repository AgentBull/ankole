---
title: コスト管理
description: Ankole の支出を制御するレバー——model profile、reasoning effort、web ツール、agent ループ予算、Workflow の fanout、background job の再試行とスロット上限。
section: Guides
order: 314
---

Ankole が使うコストの大半はモデル token であり、その大部分は、自分では形作れない利用量ではなく、少数の設定レバーで決まります。このページはレバーの名前を挙げ、それぞれが何を消費し何を節約するかを述べ、請求が高すぎるときに引く順序を示します。ここにあるレバーはすべて control plane の実際のノブであり、「Agent の使用を減らす」という類のものはありません。

決定的な性質を先に述べます。コストは*どのモデルが、何回、どのくらいの時間実行するか*の関数です。レバーはその 3 つに対応します。model profile の階層がモデルを選び、agent ループの予算が反復回数を制限し、Workflow と job の上限が fanout と再試行を縛ります。消費が発生している場所に合うレバーを引いてください。

## レバー 1: model profile の階層

8 つの組み込み Agent profile は、それぞれ別の有料経路を制御します。5 つは言語モデルを選び、3 つは web 検索、web fetch、画像生成の能力をバインドします。

| スロット | 実行される場面 | コストのレバー |
|---|---|---|
| `primary` | 主要な推論モデル。ほとんどの turn | 単一で最大のコスト項目 |
| `light` | 高頻度・低リスクの経路 | 本当に安くなるべき |
| `heavy` | 困難な合成作業 | 高価。`primary` がうまく調整されていれば滅多に使われない |
| Background Agent Jobs（内部では `coding`） | すべての Background Agent Job | 永続的なバックグラウンド作業の Provider とモデルを選ぶ |
| `vision_fallback` | `primary` が画像を処理できないとき | agent が画像を見る場合にだけバインドする |
| `web_search`、`web_fetch` | web ツール | レバー 3 を参照 |
| `image_generate` | 画像生成 | 呼び出しごとに高価。使用時にのみバインドする |

Brain には、Agent profile とは別に 5 つのインスタンス共通モデル設定があります。`brain.embedding_model` と `brain.rerank_model` は検索を制御します。`brain.web_fetch_model` は URL Source を読み、`brain.extraction_model` は会話と Source から学習し、`brain.dreaming_model` はモデルを使う保守と Skill 教訓の再確認を実行します。[AppConfigure](../app-configuration/) で一度設定してください。空の設定は該当する処理を停止または制限し、**Brain → Health** が利用できない処理を示します。全体の動作は [Brain](../brain/) を参照してください。

最も節約できる 2 つの動き:

- **`light` を本当に安いものにバインドする。** それは高頻度の経路のために存在します。`primary` とほとんど変わらない `light` は、このスロットの意味を台無しにします。
- **デフォルトで `primary` を下げるのであって、上げない。** 「高いと感じる」agent は、実際の作業より重くバインドされた `primary` であることが多いです。品質が要求するときだけ上げてください。

agent が使わないスロットはバインドを外してください。`vision_fallback` は呼び出しを発生させなくなります。空の `image_generate` profile でも、メインの Provider がネイティブの画像生成を宣言している場合は、それを利用できます。Background Agent Job は異なります。profile が未設定でも、job は Agent の `heavy` profile をフォールバックとして AIGateway 経由で実行されます。Job に別の Provider やモデルが必要な場合に、この profile を設定してください。

## レバー 2: reasoning effort

Codex reasoning effort をサポートする Provider では、`model_reasoning_effort` は 7 段のダイヤルです。`minimal | low | medium | high | xhigh | max | ultra`。より低い effort は安く速く、より高い effort は難しい問題で優れ、より高くつきます。デフォルトは `high` です。

これはモデルを切り替えるよりも細かいレバーです。`primary` が `medium` で十分なのに `high` に設定されている agent は、見える利益なしに多く使います。これを `primary` profile に設定して agent の実際の作業に合わせ、困難な合成作業を行う 1 つの agent にだけ上げてください。全部に上げるのではありません。

## レバー 3: web ツールをオンデマンドで

`web_search` と `web_fetch` は独立した profile で、呼び出しのたびにコストが発生します。2 つの動き:

- **agent が web を必要としないときはバインドを外す。** 社内専用のアシスタントは `web_search` をバインドすべきではありません。スロットが存在することは呼び出しの許可証になるからです。
- **URL がわかっているときは `web_search` より `web_fetch` を優先する。** 既知のソースの取得は 1 回の呼び出しです。検索は 1 回の呼び出しに、agent が実行すると決めた取得が追加されます。

`worker.rendered_fetch_idle_ttl_ms` AppConfigure キーは、レンダリングされた取得結果がキャッシュされる時間を制御します。TTL が高いほど同じ URL の再取得を節約し、代償として陳腐化があります。

## レバー 4: agent ループの予算

3 つの AppConfigure キーが turn ごとの消費を制限します。

| キー | 何を制限するか |
|---|---|
| `ai_agent.max_iterations` | 1 turn ごとの agent ループの反復予算 |
| `ai_agent.max_output_tokens` | turn ごとの出力 token の上限 |
| `ai_agent.inactivity_timeout_ms` | turn が回収されるまで非アクティブでいられる時間 |

`max_iterations` は、多弁な agent ループを縛るものです。2 つで足りる場面で 10 個のツールを呼ぶループは、モデルに 10 回当たります。より低い上限は agent に収束を強制します。`max_output_tokens` は各応答の大きさを縛ります。これらはインスタンス全体のデフォルトであり、通常の turn の形に設定してください。本当に難しい turn が上限に当たって「今あるものを合成した最終回答」を生むことは受け入れてください。

## レバー 5: Workflow の fanout とタスク試行

Workflow の各 `agent()` 試行は 1 回の完全なモデル Turn です。1 つの call は最大 3 回試行できるため、多数の call を作る run は、メインの会話が Workflow を 1 回しか要求していなくても、モデルと Web tool の利用を増幅できます。

| AppConfigure キー | デフォルト | 最大値 | 何を制限するか |
|---|---:|---:|---|
| `workflow.max_concurrency_per_run` | 8 | 32 | 1 つの run から同時に実行できるタスク数 |
| `workflow.max_running_per_agent` | 8 | 64 | 1 つの Agent の複数 run にまたがって実行中の Workflow タスク数 |
| `workflow.max_agent_calls_per_run` | 256 | 1,024 | 1 つの run が作成できるサブエージェント call の総数 |

同時実行数が変えるのは所要時間であり、モデル call の総数は減りません。有限の入力サイズから call 上限を決め、デプロイメントに必要な同時実行数だけを要求します。run は `concurrency` と `max_agent_calls` に低い値を要求できますが、複数 run にまたがる `max_running_per_agent` は変更できず、AppConfigure の上限も引き上げられません。

Workflow には batch 全体の token または通貨予算がありません。各タスクには通常の Turn ごとの反復、出力 token、非アクティブ時間の上限が適用されます。各タスクには狭い prompt と小さな構造化結果を使い、`null` の失敗を処理し、集約結果が大きくなりすぎる場合は collection を複数の run に分けます。タスクと結果の上限は [Workflow](../workflows/) を参照してください。

## レバー 6: background job の再試行とスロット上限

background job は再試行で token を使えます。上限がレバーです。

| 上限 | 値 | 効果 |
|---|---|---|
| `max_execution_attempts` | 5 | job は `failed` になるまで最大 5 回再試行する |
| `max_consecutive_turn_failures` | 5 | 連続する turn の失敗後に job があきらめる |
| `max_running_per_agent` | 3 | agent ごとに同時実行できる job は最大 3 つ |
| 再試行遅延 | 約 30 秒 | 再試行の間隔の下限 |
| `agent_computer.background_agent_job.max_turns_per_worker` | 設定可能 | job 向けの worker ごとの turn 上限 |

一時的に 5 回失敗する job は、5 回分の run の token を費やします。ほとんどの場合、上限があなたを守ります。設定エラーは速やかに失敗し、失敗のままです。注目すべきレバーは 3 つ目です。3 つの並行 job を持つ agent は、一度に 3 つのモデルループを実行しています。その並列性が不要なら、「一度に 1 つのことをする」という persona は、上限が許すより安く済みます。

## 消費が実際にある場所

モデルや並列性を変える前に、呼び出しを行った Agent、会話、Workflow、または Background Agent Job を確認してください。

- `GET /ai-gateway/conversations` は、直近の turn が行ったモデル呼び出しを表示します。どの profile が解決したか、呼び出し回数、どの provider か。これが、消費が `primary`（量）、`heavy`（少数の高価な呼び出し）、`web_search`（多数の小さな呼び出し）のどれかを確認する最速の方法です。
- メイン Agent に Workflow の表示を依頼します。タスク数から fanout と失敗した call がわかります。現在のバージョンには Workflow 用の Console ページも run ごとのコスト合計もありません。
- `GET /background-agent-jobs` は job の `attempts` を表示します。`attempts: 5` の job は 5 回分の run を費やしました。
- 構造化された control plane ログは、provider 呼び出しのイベント名とフィールドを持ちます。ログの取り込み先で、provider と agent ごとに集計できます。

修正は決して「Agent を減らして使う」ではありません。「この特定のレバーが、この特定の agent の作業に対して誤って設定されている」のです。

## 実例

ある導入インスタンスの請求が 1 週間で 2 倍になりました。会話のサーフェスには `primary` の呼び出しが正常に見えますが、`web_search` の呼び出しは 10 倍に増えています。`may_intervene` を使うチームアシスタント agent が、すべての channel メッセージで検索を始めたのです。修正はコストレバーではなく persona（「誰かが事実の質問をしたときだけ検索する」）です。請求は判断の問題の症状であり、判断が住む場所は persona です。

これがパターンです。コストの問題はしばしば偽装された挙動の問題であり、挙動のレバーは token 上限ではなく persona または binding ポリシーです。

## コスト管理がそうでないもの

それはリアルタイムのコストダッシュボードではありません。Ankole はそのようなものを出力しません。支出をドル金額で上限できる方法でもありません。レバーが制限するのは*呼び出しと反復*であり、ドル金額は provider のレートにそれを掛けたものです。また、会話のサーフェスを読むことの代わりでもありません。レバーは、どれが誤って設定されているかを知ってからでないと引く価値がありません。

## 次のステップ

- Agent の model profile は [Agents](../agents/#モデルを設定する) を読んでください。
- agent ループのノブとそのキーは [環境変数](../environment-variables/) を読んでください。
- 関連する会話と Job のエンドポイントは [Console API リファレンス](../console-api/) を読んでください。
- 有界のサブエージェント fanout とその上限は [Workflow](../workflows/) を読んでください。
- Job の上限は [Background Agent Jobs](../background-jobs/) を読んでください。
