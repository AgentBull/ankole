---
title: 軌跡とメッセージ形式
description: Ankole が会話メッセージと Background Agent Job の実行軌跡をどのように永続化し、モデル向け形式へ投影（プロジェクション）するかを説明します。
section: Developer guide
order: 121
---

Ankole は、Agent の実行履歴を作業の性質に応じて 2 つの異なるストアに記録します。通常のステートフルな Responses 会話のライブトランスクリプトは AIGateway が「会話メッセージ」として保存し、永続 Background Agent Job の Turn ごとの実行記録は Background Agent Jobs が「ターン軌跡（trajectory）」として保存します。このページでは、両者の保存構造、正規化された ChatML 形式、およびプロトコル固有の内部情報を除去するモデル向けプロジェクションの仕組みを解説します。前提となる設計については、[AIGateway](../ai-gateway/) および [Background Agent Jobs](../background-agent-jobs/) を参照してください。

ここで最も重要な設計原則は、**モデルがデータベース上の生の保存行を直接見ることは決してない**という点です。どちらの保存形式も、モデルに渡す際にはプロトコル固有の内部 ID が取り除かれ、その Turn 内だけで有効な呼び出しエイリアスに置き換えられた「モデル可視形式」へと投影されます。その結果、モデルが目にするのは内部 UUID やワイヤプロトコルの生フィールドではなく、「ツール呼び出し 1 → ツール結果 1」という対応関係だけになります。つまり、保存形式は永続性と監査のためにあり、プロジェクション形式はモデル推論のためにあります。

なお、本ページで扱う「AIGateway conversation」は Session ごとのモデル推論履歴を指しており、`Ankole.Conversations` が管理する参加者間の共有 Conversation / Message とは別物です。共有の会話履歴は直近の背景文脈を補うために参照されますが、保存済みのモデル応答チェーンやツール実行記録を置き換えるものではありません。

## AIGateway 会話メッセージ

ライブの会話トランスクリプトは AIGateway が所有しており、各メッセージは `ai_gateway_messages` テーブルの 1 行として保存されます。

| フィールド | 意味 |
|---|---|
| `subject_uid` | この会話履歴を所有する Principal |
| `conversation_id` | このメッセージが属する AIGateway 会話 ID |
| `type` | メッセージ種別（assistant、tool result など） |
| `role` | トランスクリプト上でのロール |
| `status` | ライフサイクル上のステータス |
| `previous_message_id` | 自己参照型の継続アンカー。API 上では `previous_response_id` として公開され、会話の連鎖を形成します |
| `content` | メッセージ本文（単一文字列ではなく構造化された JSON 値） |
| `metadata` | 呼び出し元の不透明メタデータと、AIGateway が記録する応答情報（モデル名、Provider、トークン使用量、Provider 側の生 ID） |

`previous_message_id` は会話を数珠つなぎにする継続アンカーです。各メッセージが直前のメッセージを指すことで単方向リストを形成し、API 上では `previous_response_id` として表現されるため、呼び出し元やコンテキスト圧縮処理は任意のアンカー位置から会話を再開できます。また、`metadata` フィールドには、呼び出し元が渡した不透明メタデータと並んで、AIGateway 自身が管理する事実情報（実際に使われたモデルと Provider、トークン消費量、Provider 側の生レスポンス ID）が格納されます。ここに第 2 のメッセージ配列などを二重持ちさせてはなりません。

コンテキスト圧縮（[Context compression](../context-compression-and-caching/) を参照）が実行されると、要約チェックポイントが新しい可視アンカーとして保存されます。圧縮前の古い行も障害復旧や監査のためにそのままデータベースへ残りますが、モデル向けの投影は新しい要約アンカーから始まるため、それ以前の古いメッセージが再送されることはありません。

## Background Agent Job の軌跡

Background Agent Job は、Turn ごとの実行過程を `background_agent_job_turn_items` テーブルへ追記専用（append-only）のサニタイズ済みセマンティックアイテム列として保存します。各アイテムは特定の 1 Turn に属し、順序位置、リビジョン、アイテムキー、およびセマンティックアイテム本体を持ちます。

| フィールド | 意味 |
|---|---|
| `turn_id` | このアイテムが属する Job Turn の ID |
| `position` | Turn 内での出現順序 |
| `revision` | このアイテムを受理した時点の Turn リビジョン |
| `item_key` | アイテムの不変キー（`client:` プレフィックスは呼び出し元からの入力メッセージを表す） |
| `item` | 型付きのセマンティックスレッドアイテム 1 件 |

レコードはすべて追記専用です。実行途中の steer 指示や追加プロンプトが届いた場合も、保存済みの過去アイテムを書き換えるのではなく新しいアイテムとして末尾に追記します。読み取り時には、すべてのリーダーが保存済みアイテムを正規の ChatML メッセージ列へ投影します。ChatML メッセージへ直接変換されない制御系アイテムも、スレッドリプレイのためにそのまま保持されます。アイテム行がまだ 1 件もない Turn は、空の軌跡として返されます。

なお、ツール実行結果メッセージの `metadata` には `execution_mechanism` が記録されます。モデル Provider 側で実行されたホスト型ツールには `provider_hosted`、Codex から呼び出された Ankole の動的ツールには `local_dynamic` が入るため、表示名が同じツールであっても実行経路を明確に区別できます。

Background Agent Job の軌跡が AIGateway の会話メッセージと別構造になっているのは、軌跡の所有者が会話ではなく Job 自身だからです。Job の各 Turn は独立した実行スレッドとして進み、依頼元の会話には途中の軌跡行ではなく最終的な結果イベントだけが返されます。

## モデル可視プロジェクション

コントロールプレーンでは、`Ankole.Sessions.Tools.Jobs.visible_trajectory/1` を使って保存済みの Job アイテムをモデル向け形式へ投影します。このプロジェクションでは次の処理が行われます。

- **保存用のプロトコル識別子を除去する：** 内部メッセージ ID やワイヤプロトコル固有のフィールドなど、モデルに推論材料として見せるべきではない情報をすべて取り除きます。
- **ツール呼び出し ID を Turn ローカルな連番エイリアスに置き換える：** `call_1`、`call_2` のような短い別名に変換します。これにより、内部 UUID を露出させずに「どのツール結果がどのツール呼び出しに対応するか」という必要な関係だけをモデルへ正確に伝えます。
- **本文とロールを時系列順に維持する：** 実際の発言、ツール呼び出し、ツール結果を発生した順序どおりに並べます。
- **制限・省略に関するメタデータを維持する：** 軌跡レベルの `metadata.redacted` や `metadata.content_truncated` はそのまま可視情報として残します。ページサイズ上限に収めるためにコントロールプレーン側で本文を切り詰めた場合は、`content_truncated` が設定されます。

## 2 つの形状の関係

| 観点 | AIGateway メッセージ | Background Agent Job 軌跡 |
|---|---|---|
| 保存対象 | ライブの会話トランスクリプト | Turn ごとの Job 実行記録 |
| 所有ドメイン | AIGateway | Background Agent Jobs |
| 正規形式 | AIGateway のメッセージスキーマ | セマンティックアイテムから投影された ChatML |
| モデルへの提示経路 | ステートフル Responses API | `visible_trajectory/1` によるプロジェクション |
| コンテキスト圧縮 | 新しい可視チェックポイントを保存し、過去の行も監査用に保持 | 圧縮なし（Job 側のリトライ・実行バジェットで上限管理） |

この 2 つのストアが混ざり合うことはありません。会話メッセージは AIGateway が管理し、Job の軌跡は Background Agent Jobs が管理します。Job が完了または状態変化した際は、会話メッセージストアを直接書き換えるのではなく、wakeup イベント（[Background Agent Jobs](../background-agent-jobs/) を参照）を通じてオーナー会話へ結果を報告します。

## このガイドがそうでないもの

このページは ChatML 自体の仕様書ではありません。正規の ChatML 形式は一般的な標準仕様であり、Ankole の読み取り時プロジェクションはその構造に沿って出力するだけで独自拡張は行いません。また、外部コンシューマー向けの公開 API リファレンスでもありません。`/api/v2/ai-gateway/conversations/:id/messages` や `/api/v2/background-agent-jobs/:id` といった Console ルートはオペレーター向けの管理 API であり、仕様は [Console API reference](../console-api/) にまとめられています。このページは、2 つの永続ストアにまたがるデータ形式の設計を横断的に理解するための開発者ガイドです。

## 次のステップ

- 会話メッセージストアの詳細については、[AIGateway](../ai-gateway/) を参照してください。
- Job 軌跡ストアの詳細については、[Background Agent Jobs](../background-agent-jobs/) を参照してください。
- コンテキスト圧縮と可視チェックポイントについては、[Context compression](../context-compression-and-caching/) を参照してください。
- これらのデータを取得する Console API ルートについては、[Console API reference](../console-api/) を参照してください。
