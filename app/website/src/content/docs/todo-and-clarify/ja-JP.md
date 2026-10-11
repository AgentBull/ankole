---
title: Todo と clarify
section: Developer guide
order: 124
description: コントロールプレーンの計画と質問、Codex Job の入力経路。
---

`todo` と `clarify` は `Ankole.Conversations.Tools.Session` が所有するコントロールプレーンのツールです。Driver が引数を検証し、AIGateway でモデル向けの結果を保存して現在の Run に反映します。Worker はメイン Turn のこれらのツールを所有しません。

## タスクリスト

`todo` はリストを読み、置き換え、または項目 ID で統合します。状態は `pending`、`in_progress`、`completed`、`cancelled` で、宣言は最大 256 項目を受け付けます。指示は 3 ステップ以上の複雑な作業で使用し、優先順に並べ、進行中を 1 項目にし、完了を即時記録し、失敗時に修正版を追加するよう求めます。

リストは `Ankole.Conversations.Run` の作業状態です。復旧時は現在の Run の履歴に保存された成功ツール呼び出しから再構築します。新しい Session は他の Session のリストを継承しません。Session 間で共有する知識は [Brain](../brain/) に保存します。

## 1 つの判断質問

`clarify` は結果または次の行動を選ぶために答えが必要なときだけ、独立して理解できる質問をします。Agent は現在の依頼と過去の会話を先に使い、既存の希望を聞き直さず、安全で低リスクな既定値があれば作業を中断しません。

自由回答または 2〜4 個の異なる選択肢を使えます。質問は 2,000 文字、ラベルは 200 文字、任意の説明は 500 文字までです。辞退できる行動には、行動しない選択肢を含めます。

成功すると正規化した質問と選択肢を記録し、現在の Turn を終了します。追加ツールや最終回答は出さず、ユーザーの次のメッセージが継続 Turn を開始します。質問と答えは永続的な会話記録に残ります。

## Background Job と運用

Native Codex Job は独自の入力要求経路を使います。人間の入力が必要な Job は `waiting_on_user` になり実行 slot を解放し、所有者の返信で続行します。これは Job のライフサイクル契約であり、Worker でメイン Agent の `clarify` を実行する経路ではありません。[Background Agent Jobs](../background-agent-jobs/) を参照してください。

計画状態と Turn 終了に Console の調整フラグはありません。計画や質問の選び方は Agent の指示と能力を調整します。[Agents](../agents/) と [Agent loop](../agent-loop/) を参照してください。
