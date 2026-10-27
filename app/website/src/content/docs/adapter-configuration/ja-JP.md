---
title: アダプター設定ガイド
description: Ankole の各 Identity アダプターとチャットアダプターについて、アプリの種類、認証情報、権限、検証手順を確認します。
section: Getting started
order: 3
---

このページでは、Ankole に含まれるエンタープライズ Identity アダプターとチャットアダプターを一覧でまとめています。まずは連携先のプラットフォームを **Identity Provider（IdP）** として使うか、**Channel Provider** として使うか、あるいはその両方に使うかを確認し、該当する詳細ガイドを開いてください。

初回セットアップ時には、選択した IdP のログイン callback URL とガイドへのリンクが `/setup` に表示されます。エンタープライズ Identity Provider は、Pod 管理者（`pod_admin`）が **Pod Settings**（`/api/v2/pod/admin/identity-providers`）で管理できるほか、サイト管理者も Site Console（**Console → Identity Providers**）から管理できます。サイトレベルのパスワードレス Email OTP 用 SMTP 設定（`authn.email.*`）は Site Console で管理し、外部チャットアプリケーションと Agent の紐付けは **Console → Signal Routing** で行います。

## Identity Providers

IdP を設定すると、組織向けのサインインを利用できるようになり、従業員・部門・グループの同期も可能になります。エンタープライズ Identity Provider は、Pod 管理者（`pod_admin`）が **Pod Settings** で設定するほか、サイト管理者が **Console → Identity Providers** で管理することもできます。また、Site Console でサイトの SMTP 設定（`authn.email.*`）を構成してメール配信を有効にすると、パスワードレス Email OTP サインインが表示されます。初期セットアップでは、実際のメール認証コードの確認または組織の SSO を完了することで最初の管理者を作成するため、Ankole はユーザーのパスワードを保存しません。以下の表に記載した認証情報名は設定フォームの項目名と一致しています。必要な権限、callback URL、確認手順については各ガイドを参照してください。

| プラットフォーム | 外部アプリケーション | 主な設定 | 詳細ガイド |
|---|---|---|---|
| Slack | スクラッチから作成する Slack アプリ | Client ID と Client Secret。ディレクトリ同期には Bot Token と App Token も必要 | [Slack IdP ガイド](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | シングルテナントのアプリ登録 | Tenant ID、Client ID、Client Secret、Microsoft Graph の権限 | [Entra ID ガイド](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth web client とドメイン全体委任を持つ service account | OAuth client、許可ドメイン、service account の JSON、委任された管理者メール | [Google Workspace ガイド](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | エンタープライズの自社ビルドアプリまたは Custom App | App ID、App Secret、サービスリージョン、アプリの利用範囲 | [Feishu / Lark IdP ガイド](../quickstart/?idp=lark#identity-providers) |
| DingTalk | 社内エンタープライズアプリ | Client ID、Client Secret、Corp ID、ディレクトリの権限 | [DingTalk IdP ガイド](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | 連絡先同期が任意の自社ビルドアプリ | CorpID、AgentId、アプリの Secret、連絡先同期の Secret、信頼済み IP アドレス | [WeCom IdP ガイド](../quickstart/?idp=wecom#identity-providers) |

プロバイダーを設定したら、`/setup` に表示される callback URL をそのまま正確にコピーして登録してください。手入力したり、ブラウザーがアクセスする HTTPS origin を内部のコンテナアドレスに書き換えたりしないでください。サインインに成功したら、ディレクトリのフル同期を 1 回実行し、**Principals and permission groups** にユーザー、部門、グループが反映されていることを確認します。

## Channel Providers

チャットアダプターは外部チャネルからメッセージを受信し、Agent の返信を送信します。1 つのプラットフォームで Identity とチャットの両方を連携する場合でも、本番環境ではそれぞれ別のアプリケーションを作成してください。アプリケーションを分けることで、サインイン権限、Bot 権限、公開範囲、認証情報のローテーションを互いに独立して管理できます。

| プラットフォーム | 外部アプリケーション | 接続と主な設定 | 詳細ガイド |
|---|---|---|---|
| Slack | Bot User を持つ Slack アプリ | Socket Mode。Bot Token、App Token、events、Bot scopes | [Slack channel ガイド](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | 対応する Entra アプリケーションを伴う Azure Bot | Bot Framework。App ID、Client Secret、tenant、messaging endpoint | [Teams channel ガイド](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | 別個のエンタープライズ自社ビルドアプリまたは Custom App | 常時接続。App ID、App Secret、events、bot 権限 | [Feishu / Lark channel ガイド](../quickstart/?channel=lark#chat-channels) |
| DingTalk | bot を持つ社内エンタープライズアプリ | Stream モード。Client ID と Client Secret、AI カードは任意 | [DingTalk channel ガイド](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | スーパー管理者が作成する API モードの AI bot | 常時接続。Bot ID と bot の Secret | [WeCom channel ガイド](../quickstart/?channel=wecom#chat-channels) |
| Telegram | @BotFather で作成する bot | ロングポーリング。Bot token、グループのプライバシーモードはオフ | [Telegram channel ガイド](../quickstart/?channel=telegram#chat-channels) |
| Discord | Developer Portal で作成する bot を持つアプリケーション | Gateway WebSocket。Bot token、メッセージ内容の intent、bot 権限 | [Discord channel ガイド](../quickstart/?channel=discord#chat-channels) |
| LINE | Official Account の Messaging API channel | Webhook。Channel ID、Channel secret、channel access token、webhook URL | [LINE channel ガイド](../quickstart/?channel=line#chat-channels) |
| WhatsApp | WhatsApp product を追加した Meta App と Business の電話番号 | Cloud API webhook。App ID、App secret、verify token、Phone number ID、System User token | [WhatsApp channel ガイド](../quickstart/?channel=whatsapp#chat-channels) |
| Email | IMAP と SMTP を持つ専用のメールボックス | IMAP と SMTP のホストとポート、ログイン名、パスワード、送信者認証 | [Email channel ガイド](../quickstart/?channel=email#chat-channels) |

Telegram、Discord、LINE、WhatsApp はコンシューマー向け IM であり、利用者に対応する従業員レコードがありません。そのため、Agent が応答する前に **アイデンティティ → 保留中のマッピング** で新しい送信者をアカウントに紐付ける必要があります。ただし WhatsApp では、既存のアカウントに同じ電話番号が登録されていれば送信者が自動的に紐付けられます。また、メールの送信者はメールアドレスと Identity が明示的に紐付けられている場合にのみ既知のユーザーとして扱われます。この紐付けは、従業員であればディレクトリ同期によって作成され、社外の連絡先であれば管理者が手動で作成します。詳しくは [Signal routing ルール](../signal-bindings/) を参照してください。

外部アプリケーションの準備ができたら、**Console → Signal Routing → New routing rule** を開き、Agent とアダプターを選択して認証情報を入力します。**Identity provider** 欄では同じプラットフォームの IdP を指定します。該当する IdP が 1 つだけなら自動的に選択され、複数ある場合は手動で選択します。スタンドアロンを選ぶと、その binding 固有の namespace が維持されます。この設定によってチャットの送信者と同期済みのディレクトリユーザーが同一アカウントとして統合されるため、必ずチャットアプリケーションと同じエンタープライズ組織に属する IdP を選択してください。

## 保存済み credential を更新する

Identity Provider や Signal routing ルールを編集する際、Console には暗号化された認証情報が保存済みであることだけが表示されます。トークンやシークレットがブラウザーに返されたり、ページ内に埋め込まれたりすることはありません。既存の値をそのまま維持する場合は、認証情報の入力欄を空のままにしてください。値を更新する場合のみ、新しい値を入力して保存します。現在の保存値を Console 上で確認することはできないため、古い認証情報のローテーションや失効は外部プロバイダー側で行ってください。

## 検証の順序

1. エンタープライズ IdP の SSO サインイン、または SMTP によるパスワードレス Email OTP サインインを検証し、最初の管理者が `siteadmin` および `pod_admin` として Pod ワークスペースを開き、`/site-admin-console` の Site Admin Console にアクセスできることを確認します。
2. エンタープライズ IdP を設定した場合は、ディレクトリのフル同期を実行し、Principals と permission groups を確認します。
3. チャットのルーティングルールを作成し、まずはダイレクトメッセージまたは明示的なメンションでテストします。
4. Agent がメッセージを受信して返信を送ることを確認してから、グループ監視、リアルタイムのディレクトリ同期、カードなどの高度な機能を有効にします。

プロバイダーのスコープ、アプリケーション権限、公開範囲を変更した際、プロバイダー側で再インストールや再公開が求められる場合はその手順を実施してください。また、認証情報をローテーションしたときは、その都度 Ankole 側の設定も更新してください。
