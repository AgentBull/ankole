---
title: Workflow
description: 有界の作業を並行するサブエージェントに分け、構造化された 1 つの結果を元の会話で受け取ります。
section: User guide
order: 19
---

Workflow は、メイン Agent が固定された有界のプログラムを実行し、独立したタスクをサブエージェントに委譲する機能です。多数の候補のレビュー、有限のソース集合から同じ項目を抽出する作業、独立した判断の比較、または最終合成前の検証段階に使います。

Workflow は現在の会話から開始され、`run_id` をすぐに返します。タスクの実行中も会話を続けられます。Workflow が完了または失敗すると、Ankole は元の会話を起こし、メイン Agent が結果を読んで作業を続けられるようにします。

## 適切な実行形態を選ぶ

| 必要なこと | 使用する機能 | 理由 |
|---|---|---|
| 現在の会話が必要な 1 つの短いタスク | メイン Agent の Turn | 現在の context とメイン Turn の完全な tool set を維持します。 |
| 有限の独立した確認、または固定された分析段階 | Workflow | 有界のサブエージェントタスクを並行実行し、集約結果を 1 つ返します。 |
| ファイル、workspace、後からのメッセージ、または人の入力が必要な 1 つの長い状態付きタスク | [Background Agent Job](../background-jobs/) | 一時停止と再開ができる永続的な Codex thread を所有します。 |
| schedule または webhook で起動する機械的なスクリプト | [Automation Job](../automation-jobs/) | 判断が不要な場合、トリガーがモデル Turn なしで決定性処理を実行します。 |

Workflow は汎用 DAG engine、scheduler、event bus ではありません。外部イベントや人の判断を待てません。開始後に作業の方向を変える必要がある場合は Background Agent Job を使います。

## Agent に Workflow を開始させる

有限の入力集合、独立したタスク、完了条件、最終形式を説明します。例:

```text
Run this as a Workflow. Review these 40 proposals in parallel against the five
criteria below. Return one JSON result with every verdict, the failed reviews,
and a final shortlist. Do not expand beyond these 40 proposals.
```

メイン Agent が編成プログラムを書いて開始します。JavaScript を書いたり API を呼んだりする必要はありません。Agent は run ごとの同時実行上限、サブエージェント call 数の上限、自身が利用できる custom model profile を設定できます。profile を選ばない場合、Workflow タスクは `primary` を使います。

開始操作は run ID と現在の `running` ステータスを返します。メイン Agent は run をポーリングしてはいけません。同じ会話を続け、必要なときに後から状態を尋ねられます。

## 編成の実行方法

プログラムは固定された JSON `args` を受け取り、`agent(prompt, options)` を呼び出せます。`Promise.all` 内の call は並行実行されます。通常の JavaScript 条件により、前の call が完了した後に検証や合成の段階を選べます。すべての collection と loop には、目で確認できる有限の上限が必要です。

次の簡略化したプログラムは最大 20 項目をレビューし、失敗した call を `null` のまま保持して、成功した結果を合成します。

```js
const items = args.items.slice(0, 20)
const reviews = await Promise.all(
  items.map(item =>
    agent(`Review this item: ${JSON.stringify(item)}`, {
      label: `review-${item.id}`,
      schema: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['accept', 'reject'] },
          reason: { type: 'string' }
        },
        required: ['id', 'verdict', 'reason'],
        additionalProperties: false
      }
    })
  )
)

const successful = reviews.filter(review => review !== null)
const summary = await agent(`Summarize these reviews: ${JSON.stringify(successful)}`, {
  label: 'summary'
})

return { reviews, summary }
```

プログラムと `args` は run の開始後に変わりません。control plane が再起動すると、保存済みのタスク結果から固定プログラムを replay します。保存済みの成功タスクはもう一度作成されませんが、中断されたタスクは再試行されることがあります。タスク実行を exactly-once として扱わないでください。

## 各サブエージェントが使えるもの

各 `agent()` call は、独立した短命の会話で実行されます。Agent の identity と mission、およびタスク prompt を受け取ります。プログラムが後の prompt に含めない限り、元の会話 transcript や別のタスクの結果は受け取りません。

Workflow タスクは Web tool と、Brain が有効な場合は読み取り専用の `recall` と `get_page` を使えます。永続的な書き込みは `submit_result` だけです。shell、file、MCP、Skill、schedule、Workflow、Background Agent Job の tool は受け取らず、入れ子の作業を作成できません。

各 call は完全なタスクを最大 3 回試行できます。成功した call は提出値に解決されます。試行を使い切った call は `null` に解決されるため、プログラムは失敗を記録して続行するか、run が不完全な理由を最終結果で説明できます。1 つのタスクが失敗しても、Workflow 全体が自動的に失敗することはありません。

## 構造化結果を必須にする

`agent()` call は結果 schema を宣言できます。Ankole は生成した `submit_result` tool を Provider の strict mode で送り、control plane でも提出値を再検証します。schema が拒否されてもタスクは active のままなので、サブエージェントは値を修正できます。

schema は OpenAPI 3 JSON Schema の閉じた subset であり、仕様全体ではありません。結果は `object`、`array`、`string`、`number`、`integer`、`boolean` のいずれか 1 つの非 null 型です。入れ子を含むすべての object は `properties` を宣言し、すべての property を `required` に列挙し、`additionalProperties: false` を設定する必要があります。optional object field、nullable 値、union、`$ref`、`oneOf` / `anyOf` / `allOf` はサポートされません。

schema を省略すると、タスクは string を返します。プログラムは集約した最終結果を return する必要があります。string はそのまま最終 text になり、他の JSON 値は JSON text になります。

## Run を表示、一覧、キャンセルする

メイン Agent に次の操作を依頼します。

- `show_workflow` はステータス、タスク数、最大 10 件の失敗サマリー、terminal error を報告します。完了した結果は byte offset `0` から、最大 8,000 UTF-8 byte の segment 単位で読み取ります。
- `list_workflows` はこの Agent の live または終了済み run を、1 回に最大 32 件一覧します。終了済み run には `completed`、`failed`、`cancelled` が含まれます。
- `cancel_workflow` は idempotent です。新しいタスクと遅れて届いた結果による run の復活を防ぎ、実行中のタスク Turn に停止を要求します。モデル call の停止には短い時間がかかる場合があります。

完了または失敗した run は元の会話を起こします。キャンセル済み run は完了イベントを送らないため、確認が必要な場合は Agent に状態を確認させます。

現在のバージョンには、Workflow 用の Console ページがありません。メイン Agent の Workflow tool がサポートされるユーザーサーフェスです。

## コストと容量を制御する

各タスクの各試行は 1 回の完全なモデル Turn であり、有料の Web call も行う場合があります。同時実行数が変えるのは所要時間であり、call の総数ではありません。有限の入力サイズから call 上限を決め、各タスクの prompt と結果を小さく保ちます。

| 境界 | デフォルト | ハード上限 |
|---|---:|---:|
| 1 つの run で同時実行するタスク | 8 | 32 |
| 1 つの Agent で実行中の Workflow タスク | 8 | 64 |
| 1 つの run に含まれるサブエージェント call | 256 | 1,024 |
| 1 つのサブエージェント call の試行回数 | 最大 3 | 3 |
| 保存されるプログラム | — | 256 KiB |
| 保存される `args` | — | 64 KiB |
| 1 つの call 引数 object | — | 8 KiB |
| 1 つの提出結果値 | — | 24 KiB |
| 最終集約結果 | — | 1 MiB |

管理者は最初の 3 つのインスタンス上限を [AppConfigure](../app-configuration/) で設定できます。run のリクエストはデプロイメント上限を引き上げられません。Workflow には batch 全体の token または通貨予算がなく、各タスクには通常の Turn ごとの反復、出力 token、非アクティブ時間の上限が適用されます。関連する制御については [コスト管理](../cost-management/) を参照してください。

run がサイズ境界を超える場合は、fanout を減らす、タスクから返すサマリーを短くする、または入力を複数の Workflow に分割します。プログラムまたは入力を変更する必要がある場合は、新しい run を作成します。失敗した run は、異なる code で編集または再開できません。
