---
title: Principal と permission group
description: 人と組織ディレクトリを同期し、directory group、static group、computed group でアクセスを割り当てます。
section: User guide
order: 49
---

Ankole は、人、Agent、システムサービスを Principal として表します。permission group は複数の Principal をまとめて管理します。permission grant は、Principal または group がどの resource を使用できるかを定義します。

Identity Provider は通常、従業員と組織ディレクトリを自動的に同期します。各従業員を作成したり、部門のメンバーシップを Ankole で再び管理したりする必要はありません。

## Identity Provider が組織をどう同期するか

Identity Provider で directory sync を有効にすると、Ankole はその外部ディレクトリを 2 種類のデータに変換します。

- 従業員は human Principal になります。directory sync は、名前やアバターなどの profile データを更新します。
- 部門、ユーザー group、同様の組織単位は directory permission group になります。sync はメンバーシップも更新します。

外部ディレクトリに部門の階層がある場合、子部門の人は親部門の group のメンバーにもなります。したがって、親部門に対する grant は、子部門の人々をカバーできます。

Ankole は Identity Provider を保存すると、最初の完全 sync を開始します。その後、既定では 6 時間ごとに完全 sync が実行されます。incremental sync をサポートする Provider は、次の完全 sync の前に、人と組織の変更を送信することもできます。

ディレクトリをすぐに更新するには、**Console → Identity Providers** を開き、Provider を選択して、**完全同期を実行** を選択します。sync の完了後、**Access → Principals** と **Access → Permission groups** を確認してください。

外部の identity システムは、directory group の source of truth のままです。部門とメンバーシップは企業ディレクトリで変更してください。これらの group を Ankole で手動で維持しようとしないでください。

結果に期待した人や部門がない場合は、外部アプリケーションのディレクトリ権限と可用性の範囲を確認してください。API アクセスが、アプリケーションに組織全体へのアクセスを与えるとは限りません。

最初の Identity Provider の接続は、[クイックスタート](../quickstart/#2-set-up-the-identity-provider-first) を参照してください。

## Principal を表示する

**Console → Access → Principals** を開きます。リストには、名前、UID、タイプ、状態が表示されます。

- **Human** の Principal は、Identity Provider が同期する企業ディレクトリから来ます。
- **Agent** の Principal は、Agent を作成すると現れます。
- **System** の Principal は、内部のサービス作業のために Ankole が作成します。

Principal を選択すると、その group と直接 grant を確認できます。アクセスを調査するときは、両方の領域を確認してください。Principal は直接 grant を持たなくても、group を通じてアクセスを得ることがあります。

## 正しい permission group を選択する

group の source ごとに、メンバーシップの所有者が異なります。

| Permission group | こんなときに使う | メンバーシップの所有者 |
| --- | --- | --- |
| **Directory group** | 部門やユーザー group が既に企業ディレクトリにある | Identity Provider の sync |
| **IM group** | アクセスが chat group のメンバーシップに従う必要がある | Chat channel の sync |
| **Static group** | チームが Ankole にしか存在しない、または少数のメンバーシップがめったに変わらない | 管理者 |
| **Computed group** | Principal の属性でメンバーを確実に識別できる | Ankole が評価する CEL expression |

Directory group と IM group は permission group のリストに自動的に表示されます。それらは Console では読み取り専用です。管理者は Ankole で static group と computed group を作成します。

企業ディレクトリが対象チームを既に表している場合は、directory group を使用してください。人がチームを移動したり退職したりすると、次の incremental または完全な directory sync がアクセスを調整します。

## Static group を作成する

1. **Console → Access → Permission groups** を開き、**新しいグループ** を選択します。
2. 安定した小文字の名前、表示名、説明を入力します。
3. **Static** を選択し、group を保存します。
4. 新しい group を開き、メンバーセクションで **メンバーを追加** を選択します。

新しいメンバーは、group 上のすべての grant を即座に得ます。メンバーを削除すると、そのアクセスも削除されます。

## Computed group を作成する

computed group はメンバーシップのリストを保存せず、手動のメンバーも受け付けません。Ankole がアクセスを確認するとき、1 つの CEL expression を評価して、Principal が group に属するかどうかを判断します。

group を作成するときに **Computed** を選択します。**メンバーシップ条件** に CEL expression を入力します。expression は `true` または `false` を返さなければならず、`principal` を通じて現在の Principal を読み取ります。

computed group は現在、次のフィールドを使用できます。

| フィールド | 意味 | 一般的な値 |
| --- | --- | --- |
| `principal.uid` | 安定した Principal UID | `research-agent` |
| `principal.type` | Principal のタイプ | `human`、`agent`、`system` |
| `principal.status` | Principal の状態 | `active`、`disabled` |
| `principal.displayName` | 表示名。空にできます | `Alex Smith` |
| `principal.avatarURL` | アバターの URL。空にできます | Provider からの URL |

この expression は、すべての active な human に一致します。

```text
principal.type == "human" && principal.status == "active"
```

この expression は、UID が `research-` で始まる Agent に一致します。

```text
principal.type == "agent" && principal.uid.startsWith("research-")
```

Console は expression の入力中に、一致するすべての active Principal をプレビューします。保存する前に数と名前を確認し、group が意図した以上の Principal にアクセスを与えないようにしてください。

保存後は、group の名前、タイプ、メンバーシップ条件を変更できません。規則を変更するには、新しい group を作成し、プレビューを確認し、grant を移動してから、古い group を削除します。

CEL は現在、従業員のメールアドレス、役職、部門メンバーシップを読み取れません。部門アクセスには、同期された directory group を使用してください。表示名から組織のメンバーシップを推測しないでください。

## Grant を追加する

permission group または Principal を開き、grant セクションで **新しい grant** を選択します。次に入力します。

- **resource pattern:** grant がカバーする resource。
- **action:** 許可する操作。たとえば `read` や `update`。
- **condition:** 任意の高度な制限。追加条件がない場合は空のままにします。
- **description:** このアクセスが必要な理由。

grant は permission group に付与することを優先してください。直接の Principal grant は例外のためだけに使用します。変更または削除された grant は、その所有者と関連する group メンバーに即座に影響します。

## 組織構造でアクセスを割り当てる

研究部門のすべての従業員が 1 つの Agent を見る必要があるとします。

1. Identity Provider が研究部門とそのメンバーを同期したことを確認します。
2. 対応する directory permission group を開きます。
3. 対象の Agent に対する `read` grant を group に追加します。
4. 部門メンバーの 1 人としてサインインし、対象の Agent を開ける一方、grant の外の resource は開けないことを確認します。

研究部門のメンバーシップは企業ディレクトリで変更します。次の sync の後、Ankole が group のメンバーシップを更新します。group 上の grant を変更する必要はありません。

保存が成功しただけでは十分な証拠になりません。実際のメンバーアカウントで結果を検証し、resource pattern、action、メンバーシップの source が正しいことを確認してください。

完全な permission model は [Principal と AuthZ](../principal-authz/) を参照してください。