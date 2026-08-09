---
title: アダプター設定ガイド
description: 各 Ankole の Identity と chat アダプターについて、アプリの種類、credential、権限、検証手順を調べる。
section: Getting started
order: 3
---

このページでは、Ankole に含まれるエンタープライズ Identity と chat アダプターをまとめます。まず、そのプラットフォームが **Identity Provider（IdP）** を提供するのか、**Channel Provider** を提供するのか、それとも両方かを決め、該当する詳細ガイドを開いてください。

初回セットアップ時、`/setup` は選択した IdP のログイン callback URL とガイドリンクを表示します。セットアップ後は、Identity 設定を **Console → Identity Providers** で管理します。chat アプリケーションの Agent へのバインドは、**Console → Signal Routing** で行います。

## Identity Providers

IdP は Console へのサインインを提供します。プラットフォームが対応している場合、従業員、部門、グループの同期もできます。下の credential 名は Ankole のフォームと一致します。正確な権限、provider console の操作手順、検証手順は、リンク先のガイドを参照してください。

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

外部アプリケーションを準備したら、**Console → Signal Routing → New routing rule** を開きます。Agent とアダプターを選択し、credential を入力します。IdP と chat アプリケーションの両方が同じエンタープライズ組織に属する場合にだけ、両者で同じ `platformSubjectNamespace` を使います。組織をまたいで namespace を共有しないでください。

## 検証の順序

1. IdP のサインインを検証し、最初の管理者が Console を開けることを確認します。
2. ディレクトリのフル同期を実行し、Principals と permission groups を確認します。
3. chat のルーティングルールを作成し、まず direct message または明示的なメンションでテストします。
4. Agent がメッセージを受信して返信を送ることを確認してから、グループ監視、リアルタイムのディレクトリ同期、カードなどの高度な機能を有効にします。

provider の scopes、アプリケーションの権限、リリース範囲を変更した場合は、provider が要求するときにアプリケーションを再インストールまたは再公開してください。ローテーションした credential のたびに Ankole を更新します。
