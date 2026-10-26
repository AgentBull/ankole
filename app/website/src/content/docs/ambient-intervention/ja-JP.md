---
title: アンビエント介入
description: Agent が「May intervene」グループでいつ発言するかをどう判断するか、返信がどのように質問した人に紐付くか、channel standing orders がいつ発言すべきかをどう伝えるか。
section: User guide
order: 17
---

**May intervene** が有効になっている場合 — 外部チャネルの[シグナルルーティングルール](../signal-bindings/)でグループメッセージモードを May intervene に設定した場合、またはネイティブの **Pod Chat** グループスレッドで参加 Agent の `may_intervene` ポリシーを有効にした場合 — Agent は自分宛てではないグループメッセージも確認し、人間からの新しいメッセージの各バッチに処理経路を割り当てます。デフォルトは沈黙です。必要な場合は、短い返信を開始する、新しい作業を識別する、または実行中の background job に新しい情報を渡すこともできます。

このモードでのグループ動作は、Conversation の `standing_orders` とグループ介入設定（外部チャネルでは Signal Binding の設定、Signal Binding を使用しない Pod Chat グループスレッドでは参加 Agent ごとの `may_intervene` ポリシー）という 2 つの制御に依存します。

## 各メッセージは一度だけ判断される

各 Agent は Conversation ごとに独立した判断進度を保持します。同じグループ Conversation の Agent はメッセージと standing orders を共有しますが、判断進度は共有しません。アンビエントチェックを起動するのは**人間**のメッセージのみです（Agent のメッセージが他の Agent を起こすことはありません）。各チェックは、前回のチェック後に届いたメッセージだけを判断します。古いメッセージは背景としてのみ表示され、再評価されることはありません。そのままにすると判断したメッセージが、数ラウンド後に突然回答されることはありません。

すべての判断は、action、authorization source、理由とともに記録されます。background handoff では正確な対象も記録されます。Agent が静かすぎる、または積極的すぎる場合、オペレーターは選択された経路を確認できます。

## 4 つの処理経路

- **何もしない（`NOOP`）** は Agent を沈黙させます。雑談、確認、重複する回答、または人がすでに引き受けた作業では通常この経路を使います。
- **前景返信（`FOREGROUND_REPLY`）** は、回答、明確化、調整、status 報告、または小さな限定的調査のために、短い可視 turn を 1 つ開始します。この経路は background job を作成または再開できません。
- **新しい作業（`NEW_WORK`）** は、独立した実質的な task を識別します。人からの直接の依頼または一致する standing order がある場合だけ通常の owner turn に進みます。人間を起点とする turn は **`Human ∩ Agent` の権限交差**（`interactive_principal = waking_human`）のもとで実行され、アクセスする各リソースに対して起動した人間と Agent の両方が権限を持つ必要があります。どちらの認可ソースもない場合、Agent は作業を引き受けるか確認するだけです。この確認 turn には tool がなく、job を開始できません。
- **引き継ぎ（`HANDOFF`）** は、新しいメッセージを、同じ Agent、owner Session、Conversation（外部チャネルから起動された場合はさらに同じ binding）に属する、明確に一致した 1 つの live background job に静かに送ります。候補が不完全または曖昧な場合は引き継ぎません。

recognizer 自体は background job を作成しません。処理経路と authorization source だけを選び、通常の owner turn が既存の承認規則と background-work 規則を適用します。

## 返信は質問した人に紐付く

Agent が発言を決定すると、2 つのケースを分離します。

- **誰かが Agent に尋ねている場合** — 新しいメッセージの 1 つが、@ メンションなしでも実際に Agent に質問または宛てています。その返信はそのメッセージにアンカーされます。サポートする channel では、引用返信またはスレッド返信として表示されるため、部屋の人は誰に答えているかを見られます。
- **自発的** — 誰も宛てていませんが、Agent は情報を追加することが今役立つと判断します（または standing order が一致します）。返信は通常のグループメッセージとして出ます。

帰属は検証されます。特定された質問は、判断されたバッチ内に存在し、人間から来て、その著者がまだ最新の発言者である必要があります。Agent は、部屋が先に進んだ後で古い質問を掘り起こしません。その場合、通常の自発的な返信に低下します。受け入れた質問をプラットフォームが後で削除すると、保存した帰属は degraded となり、メッセージのアンカーを解除します。判断記録と進度は残ります。

## channel standing orders

standing orders は Conversation に保存した 1 つの永続的なポリシーテキストで、参加する Agent が共有します。その部屋でいつ自発的に発言すべきかを Agent に伝えます。例:

- "CI が赤になったとき、またはデプロイが失敗したときだけ発言してください。"
- "18:00 以降、誰かが日報を投稿したら要約してください。それ以外は静かにしてください。"
- "これは顧客グループです。誰かが技術的な質問を直接しない限り、参加しないでください。"

**channel 内で Agent に伝えることで設定します。** 任意の channel メンバーが「これからは、CI が赤になったときだけここで話して」と言えます。Agent はそれをこの channel の standing orders として保存し、誰が依頼したかを記録します。変更は完全な置き換えです。指示を修正するよう依頼すると、完全な新しいテキストを保存します。「この channel の standing orders をクリアしてください」と言うと削除されます。

standing orders は 2 つの場所に届きます。経路判断はそれを channel のオペレーターポリシーとして扱い、意味が明確に一致した場合に `NEW_WORK` を許可できます。可視の owner turn も context でそれを確認します。

2 つの境界があります。

- **May intervene モードでのみ有効になります。** May intervene がオフの場合（外部チャネルで他の binding モードになっている場合、または Pod Chat グループスレッドで参加 Agent の `may_intervene` が無効になっている場合）、テキストは Conversation の `standing_orders` に保存されますが不活性のままとなり、Agent は保存後に非アクティブであることを伝えます。May intervene を有効にすると、追加の手順なしで有効になります。
- 1 つの orders テキストは最大 4000 文字です。

Console も standing orders を読み書きできます。[Console API reference](../console-api/) の `/api/v2/conversations/:conversation_id/standing-orders` エンドポイントを参照してください。

## それでも発言しすぎる、または少なすぎる場合

- **多すぎる場合:** 最初に standing orders を厳しくするかクリアし、次に Agent の役割指示を厳しくします。質疑応答の動作だけが必要なグループでは、外部チャネルの binding を **Addressed messages only** に戻すか、Pod Chat グループスレッドでその参加 Agent の `may_intervene` を無効にします。
- **少なすぎる場合:** May intervene が有効になっていること（外部チャネルの Signal Binding、または Pod Chat グループスレッドの参加 Agent の `may_intervene` 設定）を確認し、Conversation に明示的な standing order を 1 つ与えます。判断はデフォルトで保守的であり、指示がないと Agent は、実際に誰かが必要なときにだけ話します。
- **orders を保存しても何も変わらない場合:** orders を保存した後の Agent の返信を読みます。有効かどうかを報告します。非アクティブは、外部チャネルの binding モードが May intervene でないか、Pod Chat グループスレッドでその参加 Agent の `may_intervene` が有効になっていないことを意味します。

## 次のステップ

- グループメッセージモードと binding 構成: [シグナルルーティングルール](../signal-bindings/) を参照してください。
- メッセージが Agent の作業項目になる方法: [Signals](../signals/) を参照してください。
