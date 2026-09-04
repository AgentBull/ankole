---
title: はじめに
description: Ankole Agent Harness と Company Brain が提供する機能と、専用環境に配置したインスタンスの動作を説明します。
section: Getting started
order: 1
---

**Ankole は、Company Brain を備えたオープンソースの Claude Tag 代替製品です。企業向け Agent Harness が、Agent の判断に必要なコンテキスト、権限、ツール、フィードバックを提供します。**

継続して動く Agent は、会社全体の仕事で、共有の社内知識、リアルタイムのシグナル、企業の権限、Agent Computer の作業環境、永続的な実行機能を使えます。

モデルは、与えられたコンテキストを使って推論します。Harness は現在の社内情報を選び、アクセス規則を適用し、機能を付与し、障害後に仕事を復旧し、結果を次の意思決定に引き継ぎます。

## Harness が提供する機能

- Brain は、知識の出所、時点、保有者、確信度、矛盾、閲覧範囲を保持します。
- 証拠、不確実性、競合する仮説、情報不足は、人が確認できる状態で残ります。
- メッセージ、スケジュール、Webhook、外部イベントが、担当する Agent を起動します。
- ID、AuthZ、承認、監査記録、エスカレーション経路が、各 Agent の権限を定めます。
- 仕事は数時間から数日続き、新しい入力を受け、プロセス障害から復旧し、元のコンテキストへ結果を届けます。
- 修正と実際の結果は、次の意思決定が始まる前に Company Brain を更新できます。

## デプロイインスタンスの構成部品

以降のドキュメントでは、次の用語を使います。

| 部品 | 内容 | 詳細 |
|---|---|---|
| **Agent** | 固有のミッション、アクセス権、ツール、対外 ID を持つ作業主体です。ミッションと納品基準は、編集可能なファイルで定義します。1 つのインスタンスで複数の Agent を運用できます。 | [Agents](../agents/) |
| **Brain** | 共有の社内知識を保存します。出所、Claim、時点、確信度、矛盾、閲覧範囲を保持し、権限を持つ Agent に現在の知識を提供します。 | [Brain](../brain/) |
| **Session** | コンテキスト、ワークスペースの状態、実行中の誘導、キャンセル、復旧を管理する実行単位です。 | [Actor runtime](../actor-runtime/) |
| **Signal routing rule** | Agent をシグナルの送信元に接続し、その場所で使える権限を設定します。 | [Signal routing rules](../signal-bindings/) |
| **Background job** | Session から実行する長時間の仕事です。完了した結果は、元のチャネルへ配信します。 | [Background Agent Jobs](../background-agent-jobs/) |
| **Skill** | 特定の仕事を実行するための確定した手順です。Agent が改善を提案し、人が次の Session で使う変更を承認します。 | [Skills](../skills/) |
| **Principal** | 人と Agent を表す権限主体です。ランタイムは、両方に権限と監査を適用します。 | [Principal and AuthZ](../principal-authz/) |
| **Agent Computer Worker** | モデルループ、ツール、ファイル、ターミナルの状態、ストリーミング出力を実行します。 | [Agent Computer Worker](../agent-computer-worker/) |

Agent は、複数の情報源を使う長時間の調査に [Deep Research](../deep-research-job/) を使えます。[ブラウザー自動化](../browser-automation/)では、実際の Web ページを操作できます。

## 対応する意思決定の仕事

Ankole は、検査できる証拠を生成し、実際の結果で検証する重要なデジタル業務に適しています。

例には、競合する仮説を扱う業界調査、シナリオモデルを使う製品と市場の選定、再現可能な手法と複数の因果仮説を含む詳細なデータ分析があります。

Harness は多様な仕事に対応します。1 つの Agent が意思決定全体を担当できます。独立したコンテキストが相関する誤りを減らす場合は、Workflow が複数の Agent に仕事を分けます。

社内知識とシグナルがコンテキストを構成します。限定した権限で Agent が仕事を実行します。証拠と実際の結果が、次の意思決定を更新します。

## 現在のステータス

Ankole は、本番環境で稼働する完全な企業向け Agent Harness です。企業が管理する基盤に、Control Plane、Agent Computer Worker、Kernel、Company Brain、運用コンソールを配置できます。

パブリック API の互換性契約は現在策定中です。リリース間で互換性のない変更が発生する場合があります。

## 次のステップ

ローカル環境への配置手順は、[クイックスタート](../quickstart/)で説明します。[アーキテクチャ概要](../architecture/)では、各コンポーネントの責務と境界を説明します。
