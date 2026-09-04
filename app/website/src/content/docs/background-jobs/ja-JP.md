---
title: Background Agent Jobs
description: 現在の会話を利用可能なまま、再開可能なバックグラウンド Job に長い作業を委任します。
section: User guide
order: 20
---

Background Agent Job は、調査、大きなファイルセット、ドキュメント生成、データ分析、リポジトリ変更など、時間のかかる作業のためのものです。Job はバックグラウンドで独立して実行されるため、Agent と話し続けることができます。

<a href="https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/delegation.md" target="_blank" rel="noreferrer">Hermes Agent</a> や <a href="https://docs.openclaw.ai/subagents" target="_blank" rel="noreferrer">OpenClaw</a> を使っているなら、一番近い比較はサブエージェントです。メイン Agent が独立した作業を別の実行コンテキストに委任します。

Ankole は各タスクを、一時的な呼び出しではなく、完全なライフサイクルを持つ復旧可能な永続的計算として扱います。Worker の中断、クラッシュ、サーバーの再起動をまたいでも、Job は中断箇所から再開できます。

メイン Agent は追加情報を送れます。ほとんどの Job は、質問、失敗状態、最終結果を元の会話に返します。更新を求めないときは Job は沈黙を保つこともでき、後で確認できます。

## Workflow と Background Agent Job を選ぶ

どちらも作業を委譲する機能ですが、所有する作業の形が異なります。

| 使用する機能 | 選ぶ場面 |
|---|---|
| [Workflow](../workflows/) | 入力が有限で、タスクを独立して実行でき、run の開始前に段階が固定されている場合。有界の確認を並行に fanout し、集約結果を 1 つ返せます。 |
| Background Agent Job | 1 つの長いタスクに、永続的な workspace、file または browser 作業、後からのメッセージ、人への質問、または再開可能な Codex thread が必要な場合。 |

Workflow タスクは後からメッセージを受け取れず、入れ子の作業を作成できず、Job workspace も使えません。Background Agent Job は新しい情報が届いた後に方向を変えられます。継続的な context が必要なら Job を選び、有界の並行性が主な要件なら Workflow を選びます。

## Agent に Job の作成を依頼する

チャットで目標を述べ、明示的にバックグラウンド実行を依頼します。例:

```text
Run this as a Background Agent Job. Read these materials and prepare a decision
memo with evidence, disagreements, and open questions. Return the result here.
```

同じリクエストに入力ファイル、完了条件、出力形式を含めます。期限が重要なら期限も述べます。作業の進め方は Agent が決めますが、バックグラウンドで動くからといって Job に追加の権限が付与されるわけではありません。

## Job の実行中も会話を続ける

Job が開始した後も、メイン Agent は追加マテリアルを送ったり、リクエストを修正したり、現在の状態を尋ねたりできます。メッセージはアクティブな作業をステアリングしたり、あなたの回答を待つ Job を再開したりできます。

リクエストには、Agent と Job をどう協力させたいかを書きます:

- **完了したら通知:** 独立して実行できる作業に使います。結果が元の会話に返っている間も、チャットを続けられます。
- **バックグラウンドで調査してから回答を続ける:** 現在の回答が Job の結果に依存する場合に使います。
- **重要な選択の前に確認:** 方向性やコストにあなたの決定が必要な場合に使います。Job は一時停止し、元の会話で質問し、返信後に再開します。
- **サイレントに実行:** ファイルの生成だけが必要か、後で確認する予定の場合に使います。Agent に更新を送らないよう伝えます。後で質問したり、Console で確認したりできます。
- **前の Job を継続:** 作業を特定し、新しい要件を述べます。Job がまだ再開可能なら、Agent は既存のコンテキストで続けられます。

例:

```text
Compare these three proposals in the background. Notify me when you finish.
Ask me here before you expand the scope or use a paid data source.
```

Job にリポジトリ、ドキュメントセット、インストール済みツールが必要かどうかを述べます。Agent が適切なワークスペースを選択します。workspace テンプレート ID を入力したり、Job API を呼び出したりする必要はありません。

## モデル provider を選択する

すべての Job は AIGateway を使用します。Job の作成時に、Ankole は実効的な **Background Agent Jobs** モデルプロファイルを保存します。そのプロファイルが空の場合は、Agent の `heavy` プロファイルがフォールバックになります。

ChatGPT サブスクリプションを使うには、まず [ChatGPT subscription provider](../chatgpt-subscription-provider/) を作成します。次に Console で **Agents** を開き、Agent のモデルプロファイルにある **Background Agent Jobs** を探して、その provider、対象モデル、推論努力、Fast Mode を選択します。provider の認証情報プールがアカウントを選択してローテーションします。Job がアカウントを選ぶことはありません。

## Console で Job を確認する

**Background Agent Jobs** を開きます。ボードは Job を queued、active、finished の列にまとめます。Job を開くと、元のリクエスト、現在のプラン、ターンレコード、モデル使用量、結果、またはエラーを確認できます。

| ステータス | 意味 | 対処 |
|---|---|---|
| `queued` | 受け付けられ、利用可能な Worker を待機中 | 通常は待ちます。動かない場合は Worker の可用性を確認します。 |
| `running` | 作業が進行中 | Job を開いてプランと最新の進捗を確認します。 |
| `waiting_on_user` | あなたの回答または承認を待機中 | Job を作成した会話で返信します。 |
| `succeeded` | 完了 | 結果を読みます。更新を依頼した場合は、元の会話がそれを受け取ったか確認します。 |
| `failed` | 完了できなかった | エラーを読み、入力または設定を修正して、Agent に新しい Job の作成を依頼します。 |
| `stopped` | キャンセル済み | Job は続行されません。 |

`waiting_on_user` は失敗ではありません。Job は実行容量を解放し、元の会話で返信すると再開します。無関係な会話で返答しないでください。Job はその返信を自分の質問と関連付けることができません。

## Job をキャンセルする

Job を開いて **Cancel** を選択します。すでに開始したターンは停止に少し時間がかかるため、ステータスがすぐに `stopped` に変わらない場合があります。

キャンセルしても、Job がすでに生成したファイルや実行記録は削除されません。

目標の修正だけが必要なら、まず元の会話で Agent に伝えます。現在の Job が間違った方向に進んでいる、リソースを消費している、もう不要である場合は、キャンセルして新しい Job を作成します。

## よくある問題

- **Job が `queued` のまま:** 少なくとも 1 台の Worker が ready で、他の Job がすべての容量を使っていないことを確認します。
- **開始直後に失敗する:** 保存された Background Agent Jobs モデルプロファイルと、選択した provider の認証情報プールのステータスを確認します。
- **`waiting_on_user` なのに質問が届かない:** 元の会話のシグナルルーティングルールと Channel Provider を確認します。
- **成功したのにチャットに戻らない:** まずサイレントにするよう依頼されていなかったか確認します。されていなければ Job を開いて結果があるか確認し、元の会話のルーティングルールを確認します。
- **admission 済みの Job がモデルプロファイルの変更を無視する:** provider バインディングは最初の execution admission で固定されます。プロファイルの変更は、まだ admission されていない Job にのみ影響します。
