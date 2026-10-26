---
title: Principal と permission group
description: 人と組織ディレクトリを同期し、directory group、static group、computed group でアクセスを割り当てます。
section: User guide
order: 49
---

Ankole は、人、Agent、システムサービスを Principal として表します。permission group は複数の Principal をまとめて管理します。permission grant は、Principal または group がどの resource を使用できるかを定義します。

Identity Provider は従業員と組織ディレクトリを自動的に同期できるため、Ankole 側で部門メンバーシップを手動維持する必要はありません。パスワードレス Email OTP（`SiteCredential`）、Pod 招待リンク（`/join/:token`）、または管理者による事前作成を通じて参加することもできます。

## Identity Provider が組織をどう同期するか

Identity Provider で directory sync を有効にすると、Ankole はその外部ディレクトリを 2 種類のデータに変換します。

- 従業員は human Principal になります。directory sync は、名前やアバターなどの profile データを更新します。
- 部門、ユーザー group、同様の組織単位は directory permission group になります。sync はメンバーシップも更新します。

外部ディレクトリに部門の階層がある場合、子部門の人は親部門の group のメンバーにもなります。したがって、親部門に対する grant は、子部門の人々をカバーできます。

Ankole は Identity Provider を保存すると、最初の完全 sync を開始します。その後、既定では 6 時間ごとに完全 sync が実行されます。incremental sync をサポートする Provider は、次の完全 sync の前に、人と組織の変更を送信することもできます。

ディレクトリをすぐに更新するには、**Console → Identity Providers** を開き、Provider を選択して、**完全同期を実行** を選択します。sync の完了後、**Access → Principals** と **Access → Permission groups** を確認してください。

外部の identity システムは、directory group の source of truth のままです。部門とメンバーシップは企業ディレクトリで変更してください。これらの group を Ankole で手動で維持しようとしないでください。

結果に期待した人や部門がない場合は、外部アプリケーションのディレクトリ権限と可用性の範囲を確認してください。API アクセスが、アプリケーションに組織全体へのアクセスを与えるとは限りません。

最初の Identity Provider の接続は、[クイックスタート](../quickstart/#identity-providers) を参照してください。

## Principal を表示する

**Console → Access → Principals** を開きます。リストには、名前、UID、タイプ、メンバーシップ、状態が表示されます。

- **Human** の Principal は、Identity Provider でのサインインや directory sync、パスワードレス Email OTP（`SiteCredential`）、Pod 招待リンク（`/join/:token`）、または管理者による事前作成から作られます。各 human Principal はテナント内で `member` または `guest` の `membership` を持ちます。内部の `member` は組み込みの computed group である `all_humans` に含まれます。外部の `guest` は明示的な Pod ページ共有または Agent grant を必要とし、組み込み管理者グループ（`siteadmin` や `pod_admin`）への参加や Private space の利用はできず、Brain の `world` スコープも付与されません（ゲストの受け入れと Pod アクセスは `pod.allow_external_guests` が制御します）。
- **Agent** の Principal は、Agent を作成すると現れます。
- **System** の Principal は、内部のサービス作業のために Ankole が作成します。

Principal の名前または行末の **詳細を表示** を選択すると、その group と直接 grant を確認できます。Principal の UID とタイプは Identity または runtime の所有者から取得され、読み取り専用です。アクセスを調査するときは、group と直接 grant の両方を確認してください。Principal は直接 grant を持たなくても、group を通じてアクセスを得ることがあります。

## 正しい permission group を選択する

group の source ごとに、メンバーシップの所有者が異なります。

| Permission group | こんなときに使う | メンバーシップの所有者 |
| --- | --- | --- |
| **Directory group** | 部門やユーザー group が既に企業ディレクトリにある | Identity Provider の sync |
| **IM group** | アクセスが chat group のメンバーシップに従う必要がある | Chat channel の sync |
| **Signal source group** | 「このルーティングルール経由で話したことのある全員」を対象にする | Signals の受け入れ |
| **Provider members group** | ある Identity Provider が取り込んだ全員を対象にする（`<provider>:members:all`） | Identity Provider の sync |
| **Static group** | チームが Ankole にしか存在しない、または少数のメンバーシップがめったに変わらない | 管理者 |
| **Computed group** | Principal の属性でメンバーを確実に識別できる | Ankole が評価する CEL expression |

Directory group と IM group は permission group のリストに自動的に表示されます。これらのメンバーシップは外部システムから取得され、Console では読み取り専用です。管理者は Ankole で static group と computed group を作成して管理します。また、すべてのテナントには 2 つの組み込み group（その Pod 内の `tenant_console:**` 操作を付与する static group `pod_admin` と、有効な内部 human メンバーを表す computed group `all_humans`）が含まれ、特権サイトテナントにはさらに static group `siteadmin`（`site_console:**` と `tenant_console:**`）が含まれます。`siteadmin` および `pod_admin` に所属できるのは、状態が `active` でメンバーシップが `member` の human Principal のみです。

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

computed group は次のフィールドを使用できます。

| フィールド | 意味 | 一般的な値 |
| --- | --- | --- |
| `principal.uid` | 安定した Principal UID | `01958f1a-...` |
| `principal.type` | Principal のタイプ | `human`、`agent`、`system` |
| `principal.membership` | テナント内での human メンバーシップ | `human` は `member` または `guest`、`agent` と `system` は `null` |
| `principal.status` | Principal の状態 | `active`、`disabled` |
| `principal.displayName` | 表示名。空にできます | `Alex Smith` |
| `principal.avatarURL` | アバターの URL。空にできます | Provider からの URL |

この expression は、すべての active な内部 human メンバー（組み込みの `all_humans` グループと同じ条件）に一致します。

```text
principal.type == "human" && principal.membership == "member" && principal.status == "active"
```

`principal.membership == "member"` を省略すると、active な外部 `guest` も一致します。

この expression は、すべての active な Agent に一致します。

```text
principal.type == "agent" && principal.status == "active"
```

Console は expression の入力中に、一致するすべての active Principal をプレビューします。保存する前に数と名前を確認し、group が意図した以上の Principal にアクセスを与えないようにしてください。

保存後は、group の名前とタイプを変更できません。通常の computed group ではメンバーシップ条件を編集できます。保存する前に live preview を再度確認してください。組み込み computed group の条件は Ankole が管理するため、Console では読み取り専用です。

CEL は従業員のメールアドレス、役職、部門メンバーシップを読み取りません。部門アクセスには、同期された directory group を使用してください。表示名から組織のメンバーシップを推測しないでください。

## Grant を追加する

permission group または Principal を開き、grant セクションで **新しい grant** を選択します。次に入力します。

- **resource pattern:** grant がカバーする resource。
- **action:** 許可する操作。たとえば `read` や `update`。
- **condition:** 任意の高度な制限。追加条件がない場合は空のままにします。
- **description:** このアクセスが必要な理由。

grant は permission group に付与することを優先してください。直接の Principal grant は例外のためだけに使用します。変更または削除された grant は、その所有者と関連する group メンバーに即座に影響します。

grant の所有者は作成後に変更できません。別の Principal または group に grant を移すには、新しい所有者の下に grant を作成し、アクセス結果を確認してから古い grant を削除します。

## 組織構造でアクセスを割り当てる

研究部門のすべての従業員が 1 つの Agent を見る必要があるとします。

1. Identity Provider が研究部門とそのメンバーを同期したことを確認します。
2. 対応する directory permission group を開きます。
3. 対象の Agent に対する `read` grant を group に追加します。
4. 部門メンバーの 1 人としてサインインし、対象の Agent を開ける一方、grant の外の resource は開けないことを確認します。

研究部門のメンバーシップは企業ディレクトリで変更します。次の sync の後、Ankole が group のメンバーシップを更新します。group 上の grant を変更する必要はありません。

保存が成功しただけでは十分な証拠になりません。実際のメンバーアカウントで結果を検証し、resource pattern、action、メンバーシップの source が正しいことを確認してください。

## 一時停止（Suspend）と退職処理（Offboard）

人が業務を一時中断する場合や会社を離れるときは、アカウントを削除するのではなく無効化します。**Principals and permission groups** でその人を開き、**アカウントのアクセス** セクションに理由を入力して、次の 2 つの無効化区分（`disposition`）から選択します。

- **一時停止（`suspended`）**：すべてのデバイスで次に使用した時点で Console セッション、OAuth セッション、token を失効させて今後の作業を停止しますが、個人の `SiteCredential`、メールエイリアス、Pod の連絡先メール・電話番号の紐付けは保持します。復元時は認証情報を再バインドせずに同じ Human Principal をそのまま使用できます。
- **退職処理（`offboarded`）**：セッションや token を失効させて今後の作業を停止するのに加え、そのテナント内で共有されていない個人の `SiteCredential`、メールエイリアス、Pod の連絡先メール・電話番号の紐付けを解放します。監査履歴には `released_identifiers` のウォーターマークが記録され、後任者は新しい Human UID を受け取ります。すでに一時停止済みであっても、退職処理を実行すると識別子が解放されます。

どちらの区分でも、Principal UID、不変の企業サブジェクト ID、作業結果、監査履歴は保持されます。

Identity Provider もアカウントを無効化できます。Feishu の退職、凍結、同期対象のディレクトリ範囲からの確認済みの削除、および DingTalk の退職は、ディレクトリ同期を通じて同じアカウントを無効化します。provider のイベントだけでアクセスが復元されることはなく、ネットワーク障害が退職として扱われることもありません。

無効化は、その人の今後の作業を停止します。その人の権限で実行されるメッセージ、スケジュール、Background Agent Job、Workflow、自動化は、次の開始時にキャンセルまたは拒否されます。すでに開始を許可された試行は完了でき、そのように表示されます。これは停止の失敗ではありません。証明された所有者がない作業レコードは、管理者が **権限元が不明な作業を確認** で分類するまで `work_authorization_review_required` で停止します。この決定は記録され、一度だけ行えます。

その人の詳細ページには、アクセス状態、区分（disposition）、identity のソース、無効化の理由と時刻、操作者またはソース、影響を受けた各作業項目のクリーンアップ結果、各 OIDC Client へのログアウト通知結果が表示されます。クリーンアップと通知の失敗には、影響を受けたオブジェクトと再試行の操作が表示されます。

**アカウントを復元** には、管理者、理由、確認済みの本人確認が必要です。Console はまず、すべての制限を解除するよう求め、適用される group メンバーシップ、直接 grant、Pod ページ Userset grant を表示し、それらの権限ルールの承認を要求します。provider の制限は、最近のディレクトリ確認が成功して復帰を確認した後にだけ解除されます。復元後、本人は再度サインインし、Feishu の場合は個人接続を再度認可します。古いセッション、解放された credential、キャンセルされた作業は失効したままです。

`siteadmin` またはある Pod の `pod_admin` グループに有効な human 管理者が 1 人も残っていない場合、control plane のシェルにアクセスできるオペレーターは、監査されるコマンド（`Ankole.Release.recover_admin`）で確認済みの有効な内部メンバー（`member`）に管理者アクセスを付与できます。

```sh
# サイト管理権限を復旧（特権テナントの siteadmin）
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified

# 指定テナントの Pod 管理権限を復旧（そのテナントの pod_admin）
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

このコマンドは、対象グループに有効な管理者が存在する間は実行を拒否し、無効化された対象や `guest` も拒否します。

完全な permission model は [Principal と AuthZ](../principal-authz/) を参照してください。
