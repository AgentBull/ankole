---
title: Todo と clarify
description: Ankole の Agent が複雑なタスクを計画し、作業の途中で実際の曖昧さを解決する方法——todo ツール（session ごと、進行中の項目は最大 1 つ）と clarify ツール（判断の質問を 1 つあて、恒久的に記録し、その Turn を終了する）。Agent がそれぞれをどう使うか、operator が何を期待すべきでないか。
section: Developer guide
order: 124
---

`todo` と `clarify` は、Agent の構造化された計画ツールです。1 つは計画を session 内に保持し、もう 1 つは、答えが実際に結果を変える場合にだけ、あなたに質問を 1 つあてます。どちらも Worker に同梱され、`app/agent_computer/src/tools/` にあります。これらは memory でも chat surface でもありません。Agent が自分の足場を保ち、1 つの判断を求めるための仕組みです。

最初に決定的な性質を述べます。todo リストは一時的で session ごとのものであり、`clarify` の呼び出しはその Turn を終了させます。リストは session をまたいで残りません。また、Agent がいったん質問すると、次の message としてあなたの返信を待ちます。どちらのツールも永続的な truth ではありません。その役割は Memory にあります。

## 各ツールの役割

- **`todo`**（`tools/todo/todo-tool.ts`、第 182 行）——現在の session のタスクリストを管理します。3 ステップ以上の複雑なタスク、またはユーザーが複数のタスクを一度にあてた場合に使います。リストの順序が優先順位です。`in_progress` は同時に最大 1 つだけです。完了した項目はその場で `completed` にします。失敗した場合はキャンセルし、修正した項目を追加します。
- **`clarify`**（`tools/clarify/clarify-tool.ts`）——意図した結果や次の行動を選ぶために答えが必須のときだけ、ユーザーに質問を 1 つあてます。Agent はまず request とこれまでの会話を使い、すでに与えられた選好について聞き直したり、安全で低リスクな既定値があるときに尋ねたりはしません。成功すると、正規化した質問と選択肢を恒久的に記録し、現在の Turn を終了します。

todo リストは session に限定された `TodoStore` に存在します。これは作業状態であり、記録ではありません。許可される状態は 4 つです。`pending`、`in_progress`、`completed`、`cancelled`。

## Agent が todo を使うとき

作業のステップ数が、context 内に保持するだけでは負担になる程度に増えたとき、Agent は `todo` を使います。3 ステップ以上、または一度に複数のタスクがあてられることが引き金です。リストができると、Agent は 3 つのルールに従います。

1. **リストの順序が優先順位。** 先頭の項目が、次にやろうとしている項目です。
2. **進行中は最大 1 つ。** Agent は最初の項目を完了またはキャンセルするまで、2 つ目を開始しません。
3. **完了したらすぐにマーク。** 終わったステップは、現在の項目のままではなく、`completed` としてリストを離れます。失敗したステップは `cancelled` になり、修正した項目が追加されます。

todo リストが何でないか。永続的な計画ではなく、次の session に仕事を引き継ぐ手段でもありません。新しい session は空のリストから始まります。計画を session を超えて残す必要があるなら、`todo` ではなく Memory に入れます。

## Agent が clarify を使うとき

`clarify` は、意図した結果か次の行動を選ぶために答えが必須の、あの 1 つの質問のためにあります。契約は意図的に狭くしています。Agent は自己完結した質問を 1 つあて、自由形式の答えを受け入れるか、2 つから 4 つの実質的に異なる選択肢を示します。各選択肢は結果またはトレードオフを示し、辞退できる行動には「何もしない」選択肢が含まれます。その後 Agent は止まります。成功した呼び出しでは、3 つのことが起こります。

- 正規化した質問と選択肢が恒久的に記録されるため、後から判断を追跡できます。
- 現在の Turn が終了します。Agent は追加の回答を出さず、追加のツール呼び出しもしません。
- あなたの返信が次の user message として届き、Agent はそこから作業を再開します。

つまり `clarify` の呼び出しは、長い Turn の中の一時停止ではなく、きれいな手渡しです。あなたは自分のペースで答え、続く Turn はあなたの答えから始まる新しい Turn です。

Agent は質問する前に、あなたの request とこれまでの会話を使います。すでに与えた選好を繰り返さず、安全で低リスクな既定値があるときには邪魔しません。タスク後のフィードバックについては、その答えが作業の受理・改訂・継続を決める場合にだけ求めます。

## clarify と background job の関係

[background job](../background-jobs/) の内部では、`clarify` の呼び出しによって job は `waiting_on_user` 状態になります。あなたが返信するまで job は進まず、あなたの返信が job を running に戻します。あなた側から見ると、job が 1 つの質問を聞くために止まっているように見えます。Agent 側から見ると、これは同じ契約——聞く、Turn を終える、次の message を待つ——が job のライフサイクルの中で適用されたものです。状態モデルと、自分を待っている job の見つけ方は、[Background Agent Jobs](../background-jobs/) を参照してください。

## operator が触れないもの

todo store、clarify の恒久記録、Turn 終了の挙動は Worker の内部であり、Console で調整できる設定ではありません。問うべき時に問わない Agent、または問いすぎる Agent は、Worker のフラグではなく、Agent の persona と能力セットで直します。[Agents](../agents/) を参照してください。記録された判断は、それを書いたのと同じ Worker の面を通じて監査できます。operator が手で編集することはありません。

## 次のステップ

- Agent が計画するか問うかの背後の persona と能力については、[Agents](../agents/) を読んでください。
- session を超えて残る恒久知識は、Memory に属します。
- `waiting_on_user` の Job 状態と、Job 内の clarify がどう Job を一時停止するかは、[Background Agent Jobs](../background-jobs/) を読んでください。
- Turn 中にこれらのツールを実行する Worker については、[Agent Computer Worker](../agent-computer-worker/) の開発者ページを読んでください。
