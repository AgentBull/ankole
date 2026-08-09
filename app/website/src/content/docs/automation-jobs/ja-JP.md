---
title: Automation Jobs
description: 決定論的なスクリプトで Cron、Checkback、Webhook のトリガーを受け止める。機械的なチェックは静かに完了し、判断が必要なときだけ Agent が起きる。
section: User guide
order: 22
---

Cron、Checkback、webhook endpoint の 3 つのトリガーは、既定では Agent の会話を起こします。automation job は 2 つ目の受け手です。Agent が自らの Agent Home に書いて保持する決定論的なスクリプトで、トリガーをバインドすると、Agent の Turn を開始する代わりに、発火時にシステムがスクリプトを実行します。

スクリプトが、何があなたの注意に値するかを決めます。静かに終えることも、`emitEvent` を呼んでオーナーの会話に event を返すこともできます。そうすれば Agent は、スクリプトが準備した context と正確に合わせて起きます。機械的な監視はコードが担い、model は判断が必要な場面にだけ残ります。

## 向いている場合

処理が決定論的な取得、比較、パース、またはあらかじめ決められた行動であるなら、仕事を automation job に渡します。典型的な例はこうです。5 分ごとに価格をチェックし、threshold より上にとどまっている間は静かに終了し、下がったときだけ現在の価格を emit する。すると Agent が起きて検証し、あなたに通知します。各チェックのコストは model の Turn 1 回ではなく、スクリプト実行 1 回です。

毎回の発火に memory、判断、会話が必要な場合は、Agent の直接の起動（direct wake）を維持します。どちらの選択も恒久的ではありません。direct wake で始め、処理が機械的だと分かったらスクリプトに移し、また戻すこともできます。

## Agent に作成を依頼する

Console は不要です。chat で、何をチェックするか、条件、どのタイミングで起こしてほしいかを伝えます。

```text
Watch the price of 7709 for me: check every 5 minutes and alert me
only when it drops below 3.5. Stay silent otherwise. After market
close, report once whether the day's checks ran normally.
```

Agent は Agent Home 内にスクリプトを書き、手動で検証し、automation job として登録し、バインドした Cron を作成し、市場終了時の reconciliation Checkback を設定します。スクリプトの編集は再登録なしで即座に反映されます。各実行はディスク上の現在のファイルを実行します。

## 実行履歴と失敗

発火のたびに実行レコードが残ります。開始・終了時刻、status、exit code、error、上限付きログです。Agent は会話の中でこの履歴を読めます。Console の **Automation Jobs** ページにも同じ読み取り専用ビューがあります。

- 既定では、失敗した実行は記録されるだけで、ほかには何も起こりません。
- Agent に `wake_on_failure` を設定時に有効にしてもらうと、失敗した実行のたびにオーナーの会話が起きます。
- 長時間の監視では、job に reconciliation Checkback を組み合わせます。Agent が予定どおりに起きて実行履歴を読み、「14:00 以降チェックが失敗しています」のような静かな故障を声に出して報告します。

throw、非ゼロの exit、timeout はスクリプト自身の結果です。システムは再試行しません。次の発火は自然にやってきます。一方、Worker の失敗は実行を再ディスパッチするため、実行が重なったり配信が重複したりすることがあります。Agent は、再実行しても害がないようにスクリプトを書きます。

## データの規律

スクリプトが `emitEvent` で送る payload は、webhook の受信と同じ規則のもと、untrusted な input として Agent に届きます。Agent は、影響が大きな事実を行動や返答の前提にする前に、権威ある source で検証します。

## 終了

監視を終えるには、まずスクリプトを指す Cron、Checkback、webhook endpoint をキャンセルし、その次に automation job をキャンセルします。キャンセル済みの job にトリガーが発火すると、失敗した実行として記録されます。トリガーが指していない job は保持してもコストがかからず、リストの 1 行を占めるだけです。

トリガーについては [Schedules](../schedules/) と [Webhook delegations](../webhook-delegations/)、よくある形については [Automation blueprints](../automation-blueprints/)、スクリプト・SDK・コマンドの完全な契約については [Worker CLI capabilities](../cli-capabilities/) を読んでください。
