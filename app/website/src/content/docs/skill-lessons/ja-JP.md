---
title: Skill 教訓
description: 共有 Skill を変更せずに、各 Agent へ短い作業上の注意事項を届けます。
section: User guide
order: 34
---

Skill 教訓は、Agent が Skill を読み込むときに受け取る、日付付きの短い注意事項です。繰り返す tool の失敗、環境固有の問題、作業方法の誤りを避けるために使います。共有の `SKILL.md` は変わりません。

Skill 教訓は、GBrain の Skill 最適化実験から着想を得ています。Ankole は機械が書く内容を、リース付きの Agent 固有の作業メモに限定します。Agent に Skill 本文を書き換えさせません。

1 つの教訓は、1 つの Agent と 1 つの Skill に属します。すべての Agent に適用する規則は、Skill の source に記述します。

## 教訓になる内容

Ankole は次の 2 種類の作業上の注意事項を保持できます。

- 複数の Background Agent Job で発生した tool の問題または環境条件。
- Job の実行中に人が伝えた、他の task でも使える作業方法の修正。

教訓は、いつ停止するか、何を確認するか、tool をどう呼び出すかを示せます。成果物の品質、深さ、完全性、意見、語調、style を規定することはできません。Ankole は task の結果を採点して、教訓の効果を判断しません。

1 つの task だけに必要な指示は教訓ではありません。1 回限りの scope、format、用語の指定は、その task にだけ適用されます。多くの証拠 batch からは教訓が作られません。

## 必要な証拠

Ankole は、終了した Background Agent Job のうち、失敗した command または tool call がある Job、または開始後に人から message を受け取った Job を調べます。対象は直近 30 日間です。

Agent に未処理の signal Job が十分にたまると、Dreaming が reflection Job を作成します。既定の threshold は 10 です。reflection は、条件を満たす直近 30 件までの Job を受け取ります。

機械が書く教訓には、通常、2 つ以上の異なる Job の証拠が必要です。1 つの Job で十分なのは、その Job 内の人の message 自体が、教訓にまとめる再利用可能な修正を示している場合だけです。

reflection はローカル環境で読み取り専用の検査を実行できます。file の変更、network の使用、問題の修正はできません。error と tool output は信頼できない data として扱われます。

## Agent が受け取る内容

有効な教訓は、完全な Skill 手順の後にある `Agent-specific additions` section に表示されます。各項目には日付があります。人が追加した教訓は Dreaming の教訓より先に表示されます。

廃止された教訓と、再確認の猶予期間を過ぎた機械教訓は配信されません。Skill を無効にすると、その教訓も Agent の context に入りません。保存された履歴は、引き続き運用者が確認できます。

## 機械教訓を最新に保つ

Dreaming の教訓は 7 日間のリースから始まります。定期実行される Dreaming は、リース期限が近づいたとき、Ankole release が変わったとき、または Skill 本文が変わったときに教訓を再確認します。

再確認には 3 つの結果があります。

- **更新**：条件がまだ存在する場合、または新しい証拠がない場合に教訓を保持します。
- **陳腐化**：環境に条件がなくなった場合、または Skill 本文が既に教訓を含む場合に廃止します。
- **リース期限切れ**：最近の実行で条件を確認できず、陳腐化したとも判断できない場合に、期限切れの教訓を廃止します。

再確認結果がない教訓は、7 日間の猶予期間後に配信を停止します。記録は履歴に残るため、運用者は経緯を確認できます。

人が追加した教訓にはリースがありません。Dreaming はそれを変更または廃止しません。

## 教訓を追加または廃止する

1. Console で **Agent Library** を開きます。
2. scope を **グローバル既定** から対象の Agent に変更します。
3. Agent Plugin または **Skills** で対象の Skill を見つけます。
4. **教訓を追加**を選び、最初に条件を、次に実行する action を記述します。
5. 教訓が誤っている、古い、または不要になった場合は、**廃止**を選びます。

有効な Skill にだけ、人の教訓を追加できます。人の教訓には機械向けの長さ制限はありませんが、URL を含めることはできません。教訓を修正する場合は、古い項目を廃止してから新しい項目を追加します。教訓の本文は変更できません。

Console には、作成者、作成時刻、再確認日、確認済み release、証拠 Job、廃止理由が表示されます。人が取り消した内容は Dreaming の再学習禁止 list に残るため、Dreaming は同等の教訓を再追加しません。Agent は次の turn から廃止済み教訓を読みません。

## 学習を設定して状態を確認する

次の `brain.*` 設定が Skill 教訓を制御します。

| 設定 | 既定値 | 効果 |
|---|---|---|
| `brain.skill_learning_enabled` | `true` | reflection、再確認、教訓の配信を有効にします。`false` にすると、保存済みの人の教訓と Dreaming 教訓を削除せずに非表示にします。 |
| `brain.skill_learning_reflection_threshold` | `10` | 1 つの reflection Job を開始するために必要な未処理 signal Job 数を設定します。最小値は `2` です。 |
| `brain.dreaming_model` | 未設定 | リース付き教訓を再確認する model を選択します。未設定の場合、model を使う再確認を skip します。 |
| `brain.dreaming_task_cron` | `0 5 * * *` | Dreaming が reflection の trigger を評価し、期限が近い教訓を再確認する時刻を設定します。 |

**Brain → Health** を開くと、Skill 学習の有効状態、Agent ごとの有効な教訓数、直近 7 日間に追加または廃止された教訓数、最も古い有効な Dreaming 教訓の age を確認できます。

## 制限と安全性

- 機械教訓は英語の短い 1～3 文で、最大 100 token です。条件、action、任意の確認方法で構成されます。
- 1 回の reflection が 1 つの Skill に追加できる教訓は 2 件までです。その Skill に有効な教訓が既に 10 件ある場合、Dreaming は追加しません。
- 機械教訓には URL や injection 検査に一致する内容を含められません。
- 教訓は Agent 固有です。Ankole は Agent 間で教訓を共有しません。
- task を再実行しなければ、教訓が正しいことや効果を予測することはできません。日付と条件がある文面により、Agent は実行前に現在の環境を確認します。
