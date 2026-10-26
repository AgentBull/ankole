---
title: アダプター設定ガイド
description: 各 Ankole の Identity と chat アダプターについて、アプリの種類、credential、権限、検証手順を調べる。
section: Getting started
order: 3
---

このページでは、Ankole に含まれるエンタープライズ Identity と chat アダプターをまとめます。まず、そのプラットフォームが **Identity Provider（IdP）** を提供するのか、**Channel Provider** を提供するのか、それとも両方かを決め、該当する詳細ガイドを開いてください。

初回セットアップ時、`/setup` は選択した IdP のログイン callback URL とガイドリンクを表示します。エンタープライズ Identity Provider は Pod 管理者（`pod_admin`）が **Pod Settings**（`/api/v2/pod/admin/identity-providers`）で管理するほか、サイト管理者も Site Console（**Console → Identity Providers**）で管理できます。サイトレベルのパスワードレス Email OTP 用 SMTP 設定（`authn.email.*`）は Site Console で管理します。外部 chat アプリケーションの Agent へのバインドは、**Console → Signal Routing** で行います。

## Identity Providers

IdP は組織のサインインを提供し、従業員、部門、グループを同期できます。エンタープライズ Identity Provider は Pod 管理者（`pod_admin`）が **Pod Settings** で設定するほか、サイト管理者も **Console → Identity Providers** で管理できます。パスワードレス Email OTP サインインは Site Console で設定したサイトの SMTP 設定（`authn.email.*`）を使用し、メール配信が設定されている場合に表示されます。初期設定では、実際のメールコード確認または組織の SSO を完了して最初の管理者を作成します。Ankole はユーザーパスワードを保存しません。以下の認証情報名はフォームと一致します。権限、コールバック URL、確認手順は各ガイドを参照してください。

| プラットフォーム | 外部アプリケーション | 主な設定 | 詳細ガイド |
|---|---|---|---|
| Slack | スクラッチから作成する Slack アプリ | Client ID と Client Secret。ディレクトリ同期には Bot Token と App Token も必要 | [Slack IdP ガイド](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | シングルテナントのアプリ登録 | Tenant ID、Client ID、Client Secret、Microsoft Graph の権限 | [Entra ID ガイド](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth web client とドメイン全体委任を持つ service account | OAuth client、許可ドメイン、service account の JSON、委任された管理者メール | [Google Workspace ガイド](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | エンタープライズの自社ビルドアプリまたは Custom App | App ID、App Secret、サービスリージョン、アプリの利用範囲 | [Feishu / Lark IdP ガイド](../quickstart/?idp=lark#identity-providers) |
| DingTalk | 社内エンタープライズアプリ | Client ID、Client Secret、Corp ID、ディレクトリの権限 | [DingTalk IdP ガイド](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | 連絡先同期が任意の自社ビルドアプリ | CorpID、AgentId、アプリの Secret、連絡先同期の Secret、信頼済み IP アドレス | [WeCom IdP ガイド](../quickstart/?idp=wecom#identity-providers) |

provider を設定したら、callback URL を `/setup` が表示する通りに正確に登録します。手入力しないでください。ブラウザがアクセスする HTTPS origin を社内のコンテナアドレスに置き換えないでください。サインインに成功したら、ディレクトリのフル同期を 1 回実行し、**Principals and permission groups** でユーザー、部門、グループを確認します。

## Channel Providers

chat アダプターはメッセージを受信し、Agent の返信を送信します。本番環境では、1 つのプラットフォームが両方を提供する場合でも、Identity 用と chat 用に別々のアプリケーションを作成してください。この分離により、サインイン権限、bot 権限、リリース範囲、credential のローテーションが独立して保たれます。

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

Telegram、Discord、LINE、WhatsApp はコンシューマー向け IM です。そのユーザーには従業員レコードがないため、Agent が応答する前に、新しい送信者を **アイデンティティ → 保留中のマッピング** でアカウントにマッピングします。WhatsApp では、既知のアカウントがすでにその電話番号を所有している場合、送信者は自動的にマッピングされます。メールの送信者は、明示的なメールの identity 紐付けによってのみ既知になります。この紐付けは、社員についてはディレクトリ同期が作成し、それ以外の人については管理者が作成します。[Signal routing ルール](../signal-bindings/) を参照してください。

外部アプリケーションを準備したら、**Console → Signal Routing → New routing rule** を開きます。Agent とアダプターを選択し、credential を入力します。**Identity provider** フィールドは同じプラットフォームの IdP を参照します。IdP が 1 つだけならデフォルトで採用され、複数ある場合は選択が必要で、スタンドアロンの選択肢は binding 独自の namespace を保ちます。この参照によりチャットの送信者と同期されたディレクトリユーザーは 1 つのアカウントになるため、chat アプリケーションと同じエンタープライズ組織に属する IdP だけを選択してください。

## 保存済み credential を更新する

Identity Provider または signal routing ルールを編集するとき、Console は暗号化された credential が保存されていることだけを表示します。token や secret をブラウザーに返したり、ページに埋め込んだりしません。保存済みの値を維持する場合は credential フィールドを空のままにします。値を置き換える場合だけ、新しい値を入力して保存します。古い credential のローテーションまたは失効は外部 provider で実行します。現在の値を Console で表示することはできません。

## 検証の順序

1. エンタープライズ IdP の SSO サインイン、または SMTP によるパスワードレス Email OTP サインインを検証し、最初の管理者が `siteadmin` および `pod_admin` として Pod ワークスペースを開き、`/site-admin-console` の Site Admin Console にアクセスできることを確認します。
2. エンタープライズ IdP を設定した場合は、ディレクトリのフル同期を実行し、Principals と permission groups を確認します。
3. chat のルーティングルールを作成し、まず direct message または明示的なメンションでテストします。
4. Agent がメッセージを受信して返信を送ることを確認してから、グループ監視、リアルタイムのディレクトリ同期、カードなどの高度な機能を有効にします。

provider の scopes、アプリケーションの権限、リリース範囲を変更した場合は、provider が要求するときにアプリケーションを再インストールまたは再公開してください。ローテーションした credential のたびに Ankole を更新します。
