---
title: Principal と permission group
description: 従業員と組織ディレクトリを同期し、directory group、static group、computed group を使ってアクセス権限を割り当てる方法を説明します。
section: User guide
order: 49
---

Ankole では、人間、Agent、システムサービスのすべてを Principal として一貫して表現します。複数の Principal を束ねて管理する仕組みが permission group であり、どの Principal またはグループがどのリソースを操作できるかを定義するものが permission grant です。

Identity Provider を連携すれば従業員情報と組織ディレクトリを自動同期できるため、Ankole 側で部門メンバーシップを手作業で更新し続ける必要はありません。このほか、パスワードレス Email OTP（`SiteCredential`）、Pod 招待リンク（`/join/:token`）、または管理者による事前作成を通じてユーザーを追加することもできます。

## Identity Provider が組織をどう同期するか

Identity Provider でディレクトリ同期（directory sync）を有効にすると、外部ディレクトリの情報は次の 2 種類のデータとして Ankole に取り込まれます。

- **従業員：** Human Principal として登録され、名前やアバターなどのプロフィール情報も同期時に更新されます。
- **部門・ユーザーグループ・組織単位：** directory permission group として登録され、所属メンバーの構成も自動更新されます。

外部ディレクトリに部門の親子階層がある場合、子部門に所属するメンバーは親部門グループのメンバーとしても扱われます。そのため、親部門のグループに対して grant を付与すれば、配下の子部門に属するメンバー全員をまとめてカバーできます。

Identity Provider の設定を保存すると初回の完全同期が開始され、以降はデフォルトで 6 時間ごとに完全同期が実行されます。また、増分同期（incremental sync）に対応している Provider であれば、次回の完全同期を待たずにユーザーや組織の変更が随時反映されます。

ディレクトリを今すぐ最新化したい場合は、**Console → Identity Providers** を開いて対象の Provider を選択し、**完全同期を実行** をクリックします。同期が完了したら、**Access → Principals** と **Access → Permission groups** で結果を確認してください。

なお、directory group における正本（source of truth）はあくまで外部の Identity システムです。部門構成や所属メンバーを変更する際は企業ディレクトリ側を編集し、Ankole 上で手動管理しようとしないでください。

同期後に想定していたメンバーや部門が表示されない場合は、外部アプリケーション側に付与されているディレクトリ権限と公開範囲（可視性スコープ）を確認してください。API アクセスが有効になっていても、組織全体への読み取り権限が付与されているとは限りません。

最初の Identity Provider を接続する手順については、[クイックスタート](../quickstart/#identity-providers) を参照してください。

## Principal を表示する

**Console → Access → Principals** を開くと、名前、UID、タイプ、メンバーシップ、状態の一覧が表示されます。

- **Human** の Principal は、Identity Provider でのサインインやディレクトリ同期、パスワードレス Email OTP（`SiteCredential`）、Pod 招待リンク（`/join/:token`）、または管理者による事前作成によって生成されます。各 Human Principal はテナント内で `member` または `guest` の `membership` を持ちます。内部メンバー（`member`）は組み込みの computed group である `all_humans` に自動的に含まれます。一方、外部ゲスト（`guest`）は明示的な Pod ページ共有または Agent grant がないかぎりリソースへアクセスできず、組み込み管理者グループ（`siteadmin` や `pod_admin`）への参加や Private space の利用も不可で、Brain の `world` スコープも付与されません（ゲストの受け入れ可否と Pod アクセスは `pod.allow_external_guests` で制御します）。
- **Agent** の Principal は、Agent を作成した時点で自動的に生成されます。
- **System** の Principal は、内部サービスの処理用に Ankole が自動生成します。

Principal の名前、または行末の **詳細を表示** を選択すると、所属グループと直接付与された grant を確認できます。なお、Principal の UID とタイプは Identity 基盤またはランタイム側で管理される読み取り専用項目です。アクセス権の有無を調査する際は、直接の grant だけでなく所属グループ経由の grant も必ず確認してください。直接 grant がなくても、グループを通じて権限が付与されている場合があります。

## 正しい permission group を選択する

グループの種別ごとに、メンバーシップを管理する主体が異なります。用途に合わせて適切なものを選んでください。

| Permission group | 適した利用場面 | メンバーシップの所有者 |
| --- | --- | --- |
| **Directory group** | 部門やユーザーグループがすでに企業ディレクトリ上に存在するとき | Identity Provider の同期処理 |
| **IM group** | チャットグループの参加メンバーに連動してアクセス権を与えたいとき | Chat channel の同期処理 |
| **Signal source group** | 「このルーティングルール経由で発言したことがある人全員」を対象にしたいとき | Signals の取り込み処理 |
| **Provider members group** | 特定の Identity Provider から取り込まれた全員を対象にしたいとき（`<provider>:members:all`） | Identity Provider の同期処理 |
| **Static group** | Ankole 上にしか存在しないチームや、少人数で顔ぶれがほとんど変わらないとき | 管理者 |
| **Computed group** | Principal の属性条件だけで対象メンバーを確実に判別できるとき | Ankole が評価する CEL 式 |

Directory group と IM group は permission group 一覧に自動で表示され、メンバー構成は外部システム側から同期されるため Console 上では読み取り専用となります。これに対し、static group と computed group は管理者が Ankole 上で作成・管理します。また、すべてのテナントには 2 つの組み込みグループ（その Pod 内の `tenant_console:**` 操作を許可する static group `pod_admin` と、有効な内部 Human メンバー全員を表す computed group `all_humans`）があらかじめ用意されており、特権サイトテナントにはさらに static group `siteadmin`（`site_console:**` および `tenant_console:**`）が含まれます。なお、`siteadmin` と `pod_admin` に追加できるのは、状態が `active` でメンバーシップが `member` の Human Principal のみです。

対象チームが企業ディレクトリ上にすでに存在する場合は、原則として directory group を利用してください。異動や退職が発生しても、次回の増分同期または完全同期によってアクセス権が自動的に更新されます。

## Static group を作成する

1. **Console → Access → Permission groups** を開き、**新しいグループ** を選択します。
2. 変更されない小文字の識別名、表示名、説明を入力します。
3. **Static** を選択してグループを保存します。
4. 作成したグループを開き、メンバーセクションで **メンバーを追加** を選択します。

メンバーを追加すると、そのグループに設定されているすべての grant が即座に適用されます。メンバーを削除すると、該当するアクセス権も即座に外れます。

## Computed group を作成する

computed group は固定のメンバーリストを持たず、手動でのメンバー追加も受け付けません。アクセス判定のたびに Ankole が 1 つの CEL 式を評価し、対象の Principal がそのグループに該当するかを動的に判定します。

グループ作成時に **Computed** を選択し、**メンバーシップ条件** 欄に CEL 式を入力します。式は `principal` 変数から現在の Principal 情報を参照し、真偽値（`true` または `false`）を返す必要があります。

computed group の条件式では、次のフィールドを参照できます。

| フィールド | 意味 | 一般的な値 |
| --- | --- | --- |
| `principal.uid` | 不変の Principal UID | `01958f1a-...` |
| `principal.type` | Principal の種別 | `human`、`agent`、`system` |
| `principal.membership` | テナント内での Human メンバーシップ区分 | `human` は `member` または `guest`、`agent` と `system` は `null` |
| `principal.status` | Principal の状態 | `active`、`disabled` |
| `principal.displayName` | 表示名（空の場合あり） | `Alex Smith` |
| `principal.avatarURL` | アバター画像の URL（空の場合あり） | Provider から取得した URL |

たとえば次の式は、有効なすべての内部 Human メンバー（組み込みの `all_humans` グループと同一条件）に一致します。

```text
principal.type == "human" && principal.membership == "member" && principal.status == "active"
```

ここで `principal.membership == "member"` を省くと、有効な外部 `guest` も対象に含まれる点に注意してください。

次の式は、有効なすべての Agent に一致します。

```text
principal.type == "agent" && principal.status == "active"
```

Console 上で条件式を入力すると、条件に一致する有効な Principal がリアルタイムでプレビュー表示されます。意図しない相手にまで権限を広げてしまわないよう、保存前に必ず該当人数とメンバー名を確認してください。

一度保存すると、グループの名前と種別（Static / Computed）は変更できません。通常の computed group であれば保存後もメンバーシップ条件を編集できますが、更新前にも必ずライブプレビューを確認してください。なお、組み込み computed group の条件式は Ankole システム側が管理するため、Console では読み取り専用となっています。

CEL 式からは従業員のメールアドレス、役職、所属部門を参照できません。部門単位の権限制御には同期済みの directory group を使い、表示名（`displayName`）の文字列パターンから所属組織を推測するような条件は書かないでください。

## Grant を追加する

対象の permission group または Principal を開き、grant セクションで **新しい grant** を選択して、次の項目を入力します。

- **resource pattern:** 権限の対象となるリソースパターン。
- **action:** 許可する操作（`read`、`update` など）。
- **condition:** 任意の詳細条件（追加の制限が不要な場合は空欄のままにします）。
- **description:** このアクセス権を付与する理由や用途のメモ。

権限は原則として permission group に対して付与し、個別の Principal への直接 grant は例外的なケースに留めてください。grant を変更・削除すると、その所有者および該当グループのメンバー全員に即座に反映されます。

なお、作成済みの grant の所有者を後から別対象へ付け替えることはできません。別の Principal やグループへ移したい場合は、先に移行先で新しい grant を作成してアクセス動作を確認してから、古い grant を削除してください。

## 組織構造でアクセスを割り当てる

例として、研究部門の全メンバーに特定の Agent の閲覧権限を付与する手順を見てみましょう。

1. Identity Provider によって研究部門とその所属メンバーが同期されていることを確認します。
2. 対応する directory permission group を開きます。
3. 対象の Agent に対する `read` grant をそのグループに追加します。
4. 部門メンバーのアカウントで実際にサインインし、対象の Agent を開けること、および grant 対象外のリソースは開けないことを確認します。

以降、研究部門の異動があれば企業ディレクトリ側でメンバーを更新するだけで構いません。次回の同期後に Ankole 側のグループメンバーも自動更新されるため、grant 設定を作り直す必要はありません。

管理画面で保存が成功しただけでは確認として不十分です。必ず実際のメンバーアカウントで操作を試し、resource pattern、action、メンバーシップの同期元が意図どおり機能していることを確かめてください。

## 一時停止（Suspend）と退職処理（Offboard）

休職などで業務を一時的に離れる場合や退職時には、アカウントを削除するのではなく無効化（Disable）します。**Principals and permission groups** で対象ユーザーを開き、**アカウントのアクセス** セクションに理由を入力したうえで、次の 2 つの無効化区分（`disposition`）から選択します。

- **一時停止（`suspended`）**：全デバイスで次回アクセス時に Console セッション、OAuth セッション、トークンを失効させ、以降の作業を停止します。ただし、個人の `SiteCredential`、メールエイリアス、Pod の連絡先メール・電話番号の紐付けはそのまま保持されるため、復帰時には認証情報を再バインドすることなく同じ Human Principal を再開できます。
- **退職処理（`offboarded`）**：セッションやトークンを失効させて以降の作業を停止するのに加え、テナント内で他と共有されていない個人の `SiteCredential`、メールエイリアス、Pod の連絡先メール・電話番号の紐付けを解放します。監査履歴には `released_identifiers` のウォーターマークが記録され、のちに同じ連絡先を引き継いだ後任者には新しい Human UID が割り当てられます。すでに一時停止中のアカウントに対して退職処理を実行した場合も、この時点で識別子が解放されます。

いずれの区分を選んだ場合も、Principal UID、不変の企業サブジェクト ID、過去の作業成果物、監査履歴はそのまま保持されます。

また、Identity Provider 側の状態変化によってもアカウントは無効化されます。Feishu での退職・凍結・同期対象スコープからの確定削除、および DingTalk での退職ステータスは、ディレクトリ同期を通じて該当アカウントを自動的に無効化します。逆に、Provider 側のイベントだけでアクセスが自動復元されることはなく、一時的なネットワーク障害が退職扱いになることもありません。

アカウントが無効化されると、そのユーザーの権限で動く以降の作業は停止します。本人の権限に紐づくメッセージ、スケジュール、Background Agent Job、Workflow、自動化は、次回の開始タイミングでキャンセルまたは拒否されます。なお、無効化より前にすでに開始が許可されていた実行試行については最後まで完了する場合があり、画面上でもそのように表示されます（これは停止漏れではありません）。また、権限の所有者を証明できなくなった作業レコードは、管理者が **権限元が不明な作業を確認** 画面で扱いを判断するまで `work_authorization_review_required` 状態で一時停止します。この分類判断は監査記録に残され、1 回かぎり実行できます。

対象ユーザーの詳細ページでは、現在のアクセス状態、区分（disposition）、Identity ソース、無効化の理由と日時、実行した管理者または同期ソース、影響を受けた各作業アイテムのクリーンアップ結果、および各 OIDC クライアントへのログアウト通知結果を確認できます。クリーンアップや通知に失敗した項目がある場合は、対象オブジェクトと再試行ボタンが表示されます。

**アカウントを復元** を実行するには、管理者権限、復元理由の入力、および本人確認の完了が必要です。Console 上では、まず有効な制限をすべて解除するよう案内されたあと、復元後に適用されるグループメンバーシップ、直接 grant、Pod ページ Userset grant の一覧が表示され、それらの権限ルールに対する明示的な承認が求められます。Identity Provider 由来の制限については、直近のディレクトリ確認が成功して在籍復帰が確認できた後にのみ解除できます。復元が完了したら、本人が再度サインインを行い、Feishu を利用している場合は個人連携の再認可を行います。なお、失効済みの旧セッション、解放された認証情報、キャンセル済みの作業は失効したままとなり、自動では戻りません。

万が一、`siteadmin` または特定 Pod の `pod_admin` グループに有効な Human 管理者が 1 人もいなくなった場合は、コントロールプレーンのシェルにアクセスできるオペレーターが監査付きの復旧コマンド（`Ankole.Release.recover_admin`）を実行し、本人確認済みの有効な内部メンバー（`member`）に管理者権限を付与できます。

```sh
# サイト管理権限を復旧（特権テナントの siteadmin）
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified

# 指定テナントの Pod 管理権限を復旧（そのテナントの pod_admin）
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

このコマンドは、対象グループ内に有効な管理者が 1 人でも残っている間は実行を拒否し、無効化されているアカウントや外部 `guest` に対する付与も拒否します。

権限モデルの内部設計については、[Principal と AuthZ](../principal-authz/) を参照してください。
