---
title: Context の圧縮とコンパクション
description: Ankole が長い会話をモデルのコンテキスト内に保つ仕組み — AIGateway による自動履歴コンパクション、逐語的なユーザー原文の保持、常駐の長期memory用の Brain dreaming の memo compactor。
section: Developer guide
order: 116
---

長く続く会話は、やがてモデルのコンテキストウィンドウを超えます。Ankole はこれを 2 つの場所で、2 種類の異なるmemoryについて処理します。AIGateway は turn が見る会話履歴をコンパクト化し、Brain dreaming は agent の常駐の長期 memo をコンパクト化します。このページは、`ai_gateway/compaction*.ex` と `brain/dreaming/memo_compactor.ex` の実際のコードに照らして、両方を文書化します。

最初に決定的な性質を述べます。コンパクションは*設計上 lossy ですが、沈黙はしません*。コンパクションは古い turn を要約に置き換え、最近の turn を逐語的に保持し、それ自体を会話が指す永続的なアーティファクトとして記録します。元の turn はモデルのコンテキストから消え、要約が新しい参照状態になります。コンパクションは、元に戻せるキャッシュではありません。

## AIGateway の履歴コンパクション

AIGateway は、ステートフルな Responses 会話の自動履歴コンパクションを所有します。トリガー、要約、そして何が残るかはすべて `Ankole.AIGateway.Compaction` にあります。

### トリガー

コンパクションは、会話の token 使用量がしきい値を越えたときに発火します。この決定は、可視の履歴に保存された**最新の provider が返した使用量**を使います。各使用量の値は累積スナップショットであり、加算する量ではありません。AIGateway はコンテンツから token 数を推定しません。provider の使用量の数値を信頼します。

しきい値は `ai_gateway.compaction` AppConfigure キーで設定します。

| 設定 | デフォルト | 意味 |
|---|---|---|
| `threshold` | 0.50 | コンパクションをトリガーするモデルの入力コンテキストの比率 |
| `max_threshold_tokens` | 120,000 | 計算されたトリガーの絶対上限。非常に大きなコンテキストが長く待ちすぎないようにする |
| `tail_rows` | 2 | 要約と一緒に逐語的に残る最近の turn の数 |
| `user_message_budget_tokens` | 20,000 | 逐語的なユーザー原文を再再生するための token 予算 |

デフォルトは 256k のコンテキスト長を仮定しています。`max_threshold_tokens` の上限があるのは、非常に大きなコンテキストを持つモデルが、コンパクション自体が高くつくほど長い履歴を蓄積しないようにするためです。小さなコンテキストのモデルは、`small_context_trigger_ratio`（0.85）によってより早くトリガーします。

### 要約器が行うこと

しきい値を越えると、AIGateway は要約器モデルを呼び出し、古い turn の構造化された要約を作成します。コンパクションのプロンプトは、要約を**指示ではなく参照状態**として位置づけます。「会話を続けないでください。質問に答えないでください。構造化された要約だけを出力してください」。要約は意図、決定、エラーと修正を捉え、ファイルパス、関数名、エラーメッセージ、コマンドライン、ID を逐語的に保持します。言い換えられたパスやエラーは壊れた参照になるからです。

要約は会話の中で新しい最古の項目になります。モデルはそれを、続けるべき turn ではなく状態として見ます。

### 何が逐語的に残るか

要約と一緒に 2 つのものが残ります。

- **最近の turn**（`tail_rows`、デフォルト 2）— 最後の数 turn は完全なまま残り、モデルが必要とする直近のコンテキストを提供します。
- **逐語的なユーザー原文** — `CompactionRetention` は、コンパクト化された区間からユーザーメッセージを選択し、`user_message_budget_tokens` の範囲内で逐語的に再再生します。これが、assistant の turn が要約された後でもモデルが「ユーザーは X を求めた」を見られる理由です。

この組み合わせ — 古い assistant の作業の要約、逐語的な最近の turn、逐語的なユーザー原文 — が、会話がドリフトせずに続くことを可能にします。

### コンパクションアーティファクト

各コンパクションは、AIGateway が保存する永続的な `CompactionArtifact` を生成します。会話の履歴は最新のコンパクションをアンカーとして指し、後続の turn はそこから続きます。Brain のコンパクション前ナッジ（マーカー `ankole.brain.pre_compaction_nudge.v1`）はコンパクションの前に発火し、会話履歴が要約されて消える前に、agent に永続的な事実を Brain へ保存する機会を与えます。

## Brain dreaming の memo コンパクション

会話履歴とは別に、agent は**常駐の長期memory** — Brain の中の `pinned_memo` knowledge エントリ — を持つことがあります。`Brain.Dreaming.MemoCompactor` は、その memo を token 予算内に保ち、dreaming の実行をまたいで無限に成長しないようにします。

memo compactor は Brain の knowledge 設定から `pinned_memo_max_tokens` を読み、agent の pinned memo を見つけ、予算を超えたときにコンパクト化します。結果は、永続的な事実を保持するより短い memo で、同じ「参照状態であり指示ではない」という規律の下で要約器が書きます。これは dreaming 型のコンパクションです。ライブな会話ではなく、agent の常駐memoryに対してオフラインで実行されます。

## 2 つがどのように関係するか

これらは異なるmemoryであり、異なるコンパクターを持ちます。

| | AIGateway のコンパクション | Brain の memo コンパクション |
|---|---|---|
| 何をコンパクト化するか | 会話履歴（turn） | agent の pinned 長期 memo |
| いつ実行されるか | token 使用量がしきい値を越えたとき、turn の実行中 | オフライン、dreaming の間 |
| 何が残るか | 要約 + 最近の turn + ユーザー原文 | より短い memo |
| 誰が所有するか | AIGateway（会話の真実） | Brain（knowledge の真実） |
| アーティファクト | `CompactionArtifact` | 改訂された knowledge エントリ |

長い会話は、コンテキストに収まるように AIGateway のコンパクションをトリガーします。長生きする agent は、永続的なmemoryに収まるように Brain の memo コンパクションをトリガーします。2 つは直接相互作用しませんが、コンパクション前ナッジがそれらを橋渡しします。会話が要約される前に、agent に永続的な事実を会話から Brain へ昇格させる機会を与えます。

## チューニング

- **`threshold` を上げる** — agent が短い会話で作業し、コンパクションが早すぎる頻度で発火する場合。デフォルト（0.50）は保守的です。
- **`tail_rows` を上げる** — コンパクション後にモデルが直近のコンテキストを失う場合。逐語的な最近の turn が増えますが、要約のためのスペースが減ります。
- **`user_message_budget_tokens` を上げる** — コンパクト化された区間からユーザーメッセージが落とされ、モデルが何を求められたかを追えなくなる場合。
- **`pinned_memo_max_tokens` を上げる**（Brain の knowledge 設定）— agent の常駐 memo が過度に積極的にコンパクト化されている場合。

4 つすべてが AppConfigure キーで、Console を通じて変更され、現在の turn ではなく次のコンパクションで有効になります。

## このガイドがそうでないもの

プロンプトキャッシングのガイドではありません。AIGateway はここで provider 側のプロンプトキャッシングを実装しません。それは provider の関心事であり、サポートする provider の `promptCacheKey` 設定がレバーです。ロスレスの履歴でもありません。コンパクションは設計上 lossy であり、元の turn はモデルのコンテキストから消えます。そして、より短い会話の代替でもありません。コンパクションは会話がコンテキストの限界を越えて続くことを可能にしますが、数 turn ごとにコンパクト化される会話は、session に分割するか background job に委任する方が良いものです。

## 次のステップ

- AIGateway のコンセプトページについては、[AIGateway](../ai-gateway/)を参照してください。
- Brain のmemoryモデルについては、[Brain](../brain/)を参照してください。
- memo compactor を実行する dreaming プロセスについては、[Brain](../brain/)の dreaming のセクションを参照してください。