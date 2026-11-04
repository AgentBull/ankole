---
title: アダプター設定ガイド
description: Ankole の各 Identity・チャット・共有 Connector アダプターについて、アプリの種類、認証情報、権限、検証手順を確認します。
section: Getting started
order: 3
---

このページでは、Ankole に含まれるエンタープライズ Identity・チャット・Connector アダプターを一覧でまとめています。まずは連携先のプラットフォームを **Identity Provider（IdP）**、**Channel Provider**、**Connector Toolkit** のどれ（または複数）として使うかを確認し、該当する詳細ガイドを開いてください。

初回セットアップ時には、選択した IdP のログイン callback URL とガイドへのリンクが `/setup` に表示されます。テナントの外部アプリケーション接続は Pod 管理者（`pod_admin`）が **Pod → Connections**（`/connectors`、`/api/v2/pod/connectors`）で管理し、エンタープライズ Identity Provider は **Pod Settings**（`/api/v2/pod/admin/identity-providers`）または Site Console（**Console → Identity Providers**）で管理します。サイトレベルのパスワードレス Email OTP 用 SMTP 設定（`authn.email.*`）は Site Console で管理し、外部チャットアプリケーションと Agent の紐付けは **Console → Signal Routing** で行います。

`Ankole.Connectors` は共有アプリケーション認証情報（`authConfigId`）を一元管理するため、Identity Provider、IM の Signal routing ルール、MCP Toolkit、外部イベントトリガーから同じ暗号化済み接続を参照でき、重複するアプリ登録やシークレットの再入力が不要になります。たとえば **Pod → Connections**（または Console の IdP / Signal Routing 画面）で 1 つの Feishu / Lark エンタープライズアプリ接続を登録すれば、SSO とディレクトリ同期、IM メッセージ配信、MCP Toolkit（`lark-im`、`lark-approvals`、`lark-tasks`、`lark-calendar`）、Connector イベントトリガーをその 1 つの接続でまとめて動かせます。Slack や Microsoft 365（Entra ID と Teams）でも同様に 1 つの `authConfigId` を共有でき、Bot の表示名・公開範囲・ローテーション周期を分けたい場合は別々の接続を作成できます。

## Identity Providers

IdP を設定すると、組織向けのサインインを利用できるようになり、従業員・部門・グループの同期も可能になります。エンタープライズ Identity Provider は、Pod 管理者（`pod_admin`）が **Pod Settings** で設定するほか、サイト管理者が **Console → Identity Providers** で管理することもできます。どちらのフォームも `Ankole.Connectors` の接続セレクター（`authConfigId`）を共有しており、**Pod → Connections** の既存接続を選択するか、その場で新規作成できます。また、Site Console でサイトの SMTP 設定（`authn.email.*`）を構成すると、パスワードレス Email OTP サインインも利用できます。初期セットアップでは実際のメール認証コード確認または組織の SSO 完了によって最初の管理者を作成するため、Ankole はユーザーのパスワードを保存しません。

以下の表に記載した認証情報名は設定フォームの項目名と一致しています。必要な権限、callback URL、確認手順については各ガイドを参照してください。

| プラットフォーム | 外部アプリケーション | 主な設定 | 詳細ガイド |
|---|---|---|---|
| Slack | スクラッチから作成する Slack アプリ | Client ID と Client Secret。ディレクトリ同期には Bot Token と App Token も必要 | [Slack IdP ガイド](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | シングルテナントのアプリ登録 | Tenant ID、Client ID、Client Secret、Microsoft Graph の権限 | [Entra ID ガイド](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth web client とドメイン全体委任を持つ service account | OAuth client、許可ドメイン、service account の JSON、委任された管理者メール | [Google Workspace ガイド](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | エンタープライズ自社ビルドアプリまたは Custom App（`authConfigId` で SSO・IM・MCP Toolkit・トリガーに共有可能） | App ID、App Secret、サービスリージョン、アプリの利用範囲 | [Feishu / Lark IdP ガイド](../quickstart/?idp=lark#identity-providers) |
| DingTalk | 社内エンタープライズアプリ | Client ID、Client Secret、Corp ID、ディレクトリの権限 | [DingTalk IdP ガイド](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | 連絡先同期が任意の自社ビルドアプリ | CorpID、AgentId、アプリの Secret、連絡先同期の Secret、信頼済み IP アドレス | [WeCom IdP ガイド](../quickstart/?idp=wecom#identity-providers) |

プロバイダーを設定したら、`/setup` に表示される callback URL をそのまま正確にコピーして登録してください。手入力したり、ブラウザーがアクセスする HTTPS origin を内部のコンテナアドレスに書き換えたりしないでください。サインインに成功したら、ディレクトリのフル同期を 1 回実行し、**Principals and permission groups** にユーザー、部門、グループが反映されていることを確認します。

## Channel Providers

チャットアダプターは外部チャネルからメッセージを受信し、Agent の返信を送信します。`Ankole.Connectors` に対応するプラットフォーム（Feishu / Lark、Slack、Microsoft Teams など）では、Signal Routing ルールで **Pod → Connections** / Console の共有アプリケーション接続（`authConfigId`）を再利用することも、Agent ごとに異なる Bot 名・公開範囲・ローテーション方針を持たせるために専用接続を作成することもできます。Feishu / Lark 接続を再利用すれば、1 つの自社ビルドアプリで SSO、IM ルーティング、`lark-im` / `lark-approvals` / `lark-tasks` / `lark-calendar` MCP Toolkit、Connector イベント購読を App ID・App Secret の再入力なしで賄えます。

| プラットフォーム | 外部アプリケーション | 接続と主な設定 | 詳細ガイド |
|---|---|---|---|
| Slack | Bot User を持つ Slack アプリ | Socket Mode。共有接続（`authConfigId`）または Bot Token、App Token、events、Bot scopes | [Slack channel ガイド](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | 対応する Entra アプリケーションを伴う Azure Bot | Bot Framework。共有接続（`authConfigId`）または App ID、Client Secret、tenant、messaging endpoint | [Teams channel ガイド](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | 共有または個別のエンタープライズ自社ビルドアプリ / Custom App | 常時接続。共有接続（`authConfigId`）または App ID、App Secret、events、bot 権限 | [Feishu / Lark channel ガイド](../quickstart/?channel=lark#chat-channels) |
| DingTalk | bot を持つ社内エンタープライズアプリ | Stream モード。Client ID と Client Secret、AI カードは任意 | [DingTalk channel ガイド](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | スーパー管理者が作成する API モードの AI bot | 常時接続。Bot ID と bot の Secret | [WeCom channel ガイド](../quickstart/?channel=wecom#chat-channels) |
| Telegram | @BotFather で作成する bot | ロングポーリング。Bot token、グループのプライバシーモードはオフ | [Telegram channel ガイド](../quickstart/?channel=telegram#chat-channels) |
| Discord | Developer Portal で作成する bot を持つアプリケーション | Gateway WebSocket。Bot token、メッセージ内容の intent、bot 権限 | [Discord channel ガイド](../quickstart/?channel=discord#chat-channels) |
| LINE | Official Account の Messaging API channel | Webhook。Channel ID、Channel secret、channel access token、webhook URL | [LINE channel ガイド](../quickstart/?channel=line#chat-channels) |
| WhatsApp | WhatsApp product を追加した Meta App と Business の電話番号 | Cloud API webhook。App ID、App secret、verify token、Phone number ID、System User token | [WhatsApp channel ガイド](../quickstart/?channel=whatsapp#chat-channels) |
| Email | IMAP と SMTP を持つ専用のメールボックス | IMAP と SMTP のホストとポート、ログイン名、パスワード、送信者認証 | [Email channel ガイド](../quickstart/?channel=email#chat-channels) |

Telegram、Discord、LINE、WhatsApp はコンシューマー向け IM であり、利用者に対応する従業員レコードがありません。そのため、Agent が応答する前に **アイデンティティ → 保留中のマッピング** で新しい送信者をアカウントに紐付ける必要があります。ただし WhatsApp では、既存のアカウントに同じ電話番号が登録されていれば送信者が自動的に紐付けられます。また、メールの送信者はメールアドレスと Identity が明示的に紐付けられている場合にのみ既知のユーザーとして扱われます。この紐付けは、従業員であればディレクトリ同期によって作成され、社外の連絡先であれば管理者が手動で作成します。詳しくは [Signal routing ルール](../signal-bindings/) を参照してください。

外部アプリケーションの準備ができたら、**Console → Signal Routing → New routing rule** を開き、Agent とアダプターを選択して、既存の接続（`authConfigId`）を選ぶか新しい認証情報を入力します。**Identity provider** 欄では同じプラットフォームの IdP を指定します。該当する IdP が 1 つだけなら自動的に選択され、複数ある場合は手動で選択します。スタンドアロンを選ぶと、その binding 固有の namespace が維持されます。この設定によってチャットの送信者と同期済みのディレクトリユーザーが同一アカウントとして統合されるため、必ずチャットアプリケーションと同じエンタープライズ組織に属する IdP を選択してください。

## 保存済み credential を更新する

**Pod → Connections** の共有接続でも、Console の Identity Provider や Signal routing ルールでも、画面には暗号化された認証情報が保存済みであることだけが表示され、生のトークンやシークレットがブラウザーへ返されることはありません。既存の値を維持する場合は入力欄を空のままにし、更新する場合のみ新しい値を入力して保存します。共有接続（`authConfigId`）のシークレットを更新するとシークレットバージョンが進み、その接続を参照しているすべての Identity Provider・IM チャネル・Connector Toolkit が再構成されます。保存値を Ankole 上から取り出すことはできないため、古い認証情報のローテーションや失効は外部プロバイダー側で行ってください。

## 検証の順序

1. エンタープライズ IdP の SSO サインイン、または SMTP によるパスワードレス Email OTP サインインを検証し、最初の管理者が `siteadmin` および `pod_admin` として Pod ワークスペースを開き、`/site-admin-console` の Site Admin Console にアクセスできることを確認します。
2. エンタープライズ IdP を設定した場合は、ディレクトリのフル同期を実行し、Principals と permission groups を確認します。
3. チャットのルーティングルールを作成し（対応プラットフォームでは共有接続 `authConfigId` を再利用可能）、まずはダイレクトメッセージまたは明示的なメンションでテストします。
4. Agent がメッセージを受信して返信を送ることを確認してから、グループ監視、リアルタイムのディレクトリ同期、対話型カード、または **Pod → Connections** での Connector Toolkit とメンバー個人 OAuth 連携を有効にします。

プロバイダーのスコープ、アプリケーション権限、公開範囲を変更した際、プロバイダー側で再インストールや再公開が求められる場合はその手順を実施してください。また、認証情報をローテーションしたときは、その都度 Ankole 側の設定も更新してください。
