---
title: はじめに
description: Ankole とは何か、自律的な労働力が copilot とどう違うのか、プライベートデプロイインスタンスの構成部品。
section: Getting started
order: 1
---

**Ankole はオープンソースの AI Workforce OS です。AI agent を、業務機能を遂行し、成果によって評価される自律的な労働力に変えます。**

Agent に投資調査の機能、権限境界、tools、成果指標を与えます。Agent は仮説を維持し、レポートを生成し、コールを追跡し、後の成果と比較します。

copilot は次のプロンプトを待ちます。仕事を所有しているのは人だからです。Ankole Agent は自分の機能内で次のアクションを所有し、承認、例外、説明責任の境界で人に戻ります。

## 自律的な労働力が copilot とどう違うか

- **チャット persona ではなく業務機能。** 各 Agent は、継続的な責任、期待される成果物、運用 context、結果指標を持ちます。
- **活動ではなく成果。** 仕事は、収益、risk、順位、承認率、単位コストなど、業務にとって重要な数字で評価されます。
- **次のステップの提案ではなく実行 loop。** Agent が計画し、tools を使い、フォローアップし、失敗から復旧し、納品します。
- **境界のある権限。** Identity、AuthZ、承認、監査記録、エスカレーションパスが、Agent にできることを定義します。
- **1 回の request ではなく長時間の作業。** Session は数時間または数日動き、新しい入力を受け、失敗後に復旧し、運用 context を保持できます。

自律的な作業は現在の context に依存します。Ankole は、すべての古いメッセージを同じように真実として扱うのではなく、ルール、決定、修正、成果を時刻と出所とともに記録します。

Brain は古いルールを退役させ、矛盾を解決し、予測を後日の結果と比較します。各実行は、より正確な運用認識から始まります。

## デプロイインスタンスの構成部品

これらの言葉は以降のドキュメント全体に繰り返し登場するので、ここで一度だけ定義します。

| 部品 | 内容 | 詳細 |
|---|---|---|
| **Agent** | 独自のミッション、アクセス、tools、memory、対外 identity を持つ作業 identity。ミッションと配信基準はいつでも編集できるファイルです。1 つのデプロイインスタンスに複数保持できます。 | [Agents](../agents/) |
| **Session** | 長時間実行される実行単位であり、context、workspace 状態、steering、キャンセル、回復が交わる場所。 | [Actor runtime](../actor-runtime/) |
| **Signal routing rule** | Agent を signal ソースに接続し、そこでできることの境界を設定します。 | [Signal routing rules](../signal-bindings/) |
| **Background job** | Session から送り出される作業で、数時間実行でき、送り出し元の channel に納品して戻ります。 | [Background Agent Jobs](../background-agent-jobs/) |
| **Memory** | channel ルールと長期 memory。経験から予測し、現実によって修正される world model。 | [Memory](../memory/)、[Brain](../brain/) |
| **Skill** | ある種の仕事をこなす定まった方法。agent が改善を提案でき、人が次の session 用に承認します。 | [Skills](../skills/) |
| **Principal** | 人と agent は同じ種類の主体であるため、runtime は両者に権限と監査を適用します。 | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | 実行フロア。LLM loop、tools、files、terminal 状態、streaming 出力がすべてここで実行されます。 | [Agent Computer Worker](../agent-computer-worker/) |

Agent はまた、長時間の多ソース調査に [Deep Research](../deep-research-job/) を、実際の Web ページを操作する [browser automation](../browser-automation/) を使うこともできます。

## 実行できる業務機能

Ankole は、デジタルで完結でき、検査可能な成果物を生成し、宣言された成果指標を持つ仕事に適しています。

例としては、増分 ROAS で測定されるパフォーマンスマーケティング、risk 調整後リターンで測定されるトレーディング、順位変動で測定される SEO、登録率で測定される特許出願などがあります。

単位は業務機能であって、Agent 数ではありません。マルチエージェントの調整は実装の選択であり、製品の約束ではありません。

共通のコントラクトは次のとおりです: **機能を定義し、境界のある権限を付与し、Agent に作業させ、成果を評価すること。**

## 現在のステータス

Ankole は、本番環境で稼働する完全でセルフホスト可能な AI Workforce OS ですが、まだ初期段階です。control plane、Agent Computer Worker、kernel、オペレーターコンソールはエンドツーエンドで動作します。

パブリック API にはまだ互換性コントラクトがありません。それができるまで、リリース間の破壊的変更を想定してください。

## 次のステップ

[クイックスタート](../quickstart/) でローカルに動かしてみてください。全体像を先に見たい場合は、[アーキテクチャ概要](../architecture/) を読んでください。
