---
title: はじめに
description: Ankole デジタル本社、Agent Harness、Meta Ankole の Company Brain が提供する機能と、プライベートデプロイインスタンスの仕組みを説明します。
section: Getting started
order: 1
---

**Ankole は、Meta Ankole の Company Brain を中核に据えたオープンソースのデジタル本社およびエンタープライズ Agent Harness です。共同作業のための Pod ワークスペースと、メンバーごとのパーソナルアシスタントおよび専門 AI 同僚を組み合わせ、Agent が根拠を示しながら継続業務を遂行するためのコンテキスト・権限・ツール・フィードバック基盤を提供します。**

プライベート環境では、人と Agent が Pod Docs、シャード化された Base、React + TypeScript Applet、Pod Chat、外部チャットツールを横断して協働し、その裏側を共有知識、統合 Connectors、Function Runtime、専用の Agent Computer Worker が支えます。

単体の言語モデルは渡されたプロンプトの範囲でしか推論できませんが、Ankole は最新の社内事実の組み立て、実行時の Principal・Drive 権限検査、分離コンテキスト間の委譲、障害後の処理再開、そして修正指摘や実際の結果の次回業務への反映までを一貫して担います。

## Ankole が提供する機能

- **Pod デジタル本社：** 階層型 Docs の共同編集、物理シャード化された Base テーブルでの業務データ管理、LLM 不要の公開済み Applet Action を備えた React + TypeScript Applet、マルチプレイヤー Pod Chat を提供し、Slack・Microsoft Teams・Lark/Feishu・DingTalk・WeCom とも連携します。
- **パーソナルアシスタントと AI 同僚：** すべての社内メンバーには本人の共同作業権限を引き継ぐ 1 対 1 の**パーソナルアシスタント**が用意され、専門業務を担う **AI 同僚**は固有の Principal 権限・Action Card 承認・分離された Peer A2A 委譲（`send_to_agent`）のもとで稼働します。
- **Meta Ankole（`Brain`・`Skills`・契約）：** 出所・Claim・時点・確信度・矛盾・公開範囲を管理する **Brain** オントロジーグラフと、共有 **Skills**、継承可能な `AGENTS.md` / `DESIGN.md` の行動・デザイン契約をひとつの基盤に統合します。
- **統合 Connectors と MCP ゲートウェイ：** `Ankole.Connectors` がテナント共有のアプリ認証情報、メンバー個人の OAuth 認可（`/connectors`）、Lark/Feishu・GitHub・Linear やリモート MCP サーバー向けのコントロールプレーン MCP ゲートウェイを管理し、生のシークレットを Worker や Applet 分離環境に渡しません。
- **イベント駆動と障害復旧：** チャットメッセージ、定期スケジュール、Webhook、Connector トリガーが Session・Background Agent Job・決定論的な Applet Action を起動し、プロセス障害後も PostgreSQL から正確に再開します。
- **継続的な学習ループ：** Dreaming が実際の Job 実行履歴から 7 日間リースの Skill 注意事項（教訓）を自動で有効化し、予測と実際の結果も照合します。恒久的な注意事項や共有 Skill は人が Meta Ankole で整備します。

## デプロイインスタンスの構成要素

ドキュメント全体を通して、次の主要概念が登場します。

| 構成要素 | 内容 | 詳細 |
|---|---|---|
| **Pod** | 人と Agent が協働する共有デジタル本社です。階層型 Docs、物理シャード化 Base テーブル、React + TypeScript Applet（公開済み Applet Action を含む）、統合 Drive、マルチプレイヤー Pod Chat を備えます。 | [アーキテクチャ概要](../architecture/) |
| **パーソナルアシスタントと AI 同僚** | 2 種類の Agent ロールです。メンバーごとに 1 対 1 で紐付き所有者の共同作業権限で動く**パーソナルアシスタント**と、固有の Principal 権限を持ち分離された Peer A2A（`send_to_agent`）で連携する専門 **AI 同僚**で構成されます。 | [Agents](../agents/) |
| **Meta Ankole（`Brain`・`Skills`・契約）** | **Brain** オントロジーグラフと出典付き Claim、再利用可能な **Skills**（Agent ごとのリース教訓を含む）、そして `AGENTS.md` / `DESIGN.md` 契約を束ねる組織知識基盤です。 | [Brain](../brain/)、[Skills](../skills/)、[Agent Library](../agent-library/) |
| **統合 Connectors** | テナントのアプリ接続（`authConfigId`）、個人 OAuth（`/connectors`）、外部イベント購読、そして Lark・GitHub・Linear などの Toolkit を Worker や Function Runtime へ提供するコントロールプレーン MCP ゲートウェイです。 | [MCP の利用](../using-mcp/) |
| **Principal** | 人・Agent・内部 `system` サービス（`system`、`ankole_brain`）を表す `(tenant_id, uid)` の責任主体です。`Ankole.AuthZ` が実行時の権限判定と監査記録を Principal 単位で行います。 | [Principal and AuthZ](../principal-authz/) |
| **Session** | 会話や Peer A2A 連携における Agent の実行単位で、コンテキスト、途中誘導、キャンセル、コールドウェイク時の会話ローテーション、障害復旧を管理します。 | [Sessions](../sessions/) |
| **Signal routing rule** | IM チャネル、Webhook、スケジュール、Base/Applet イベント、Connector トリガーを対象の Agent Session または公開済み Applet Action に結び付けるルールです。 | [Signal routing rules](../signal-bindings/) |
| **Background Agent Job** | 専用 Worker 上で数時間にわたり非同期実行できる永続的な Codex タスクで、途中の確認質問や最終成果物を元の会話へ返します。 | [Background Agent Jobs](../background-agent-jobs/) |
| **Function Runtime** | ステートレスな `ankole-function-runtime` サービスです。分離された TypeScript 実行環境で Pod Applet バックエンド、公開済み Applet Action（[Automation Jobs](../automation-jobs/)）、PTC、Workflow を動かし、コントロールプレーンの MCP ホストへブリッジします。 | [アーキテクチャ概要](../architecture/) |
| **Agent Computer Worker** | 各 Agent 専用の計算環境です。シェルツール、ヘッドレスブラウザー、Codex Job、MCPorter、Git ヘルパー、永続 `/workspace` Home に加え、統合 Drive・Brain・Skills・契約を投影する `/drive` FUSE マウントを備えます。 | [Agent Computer Worker](../agent-computer-worker/) |

さらに、複数情報源を横断する本格調査には [Deep Research](../deep-research-job/) を、実際の Web ページ操作には [ブラウザー自動化](../browser-automation/) を利用できます。

## 支える意思決定と継続業務

Ankole は、検証可能な根拠と成果物が求められる重要なデジタル業務向けに設計されています。たとえば、競合する仮説を検証する業界調査、シナリオモデルにもとづく製品・市場評価、再現可能なコードによるデータ分析、そして Pod Base・Applet・GitHub・Linear・企業チャットをまたぐ継続的な業務運用などに対応します。

課題の性質に応じて、メンバーのパーソナルアシスタントが本人権限で直接処理することも、Peer A2A（`send_to_agent`）で専門 AI 同僚に委譲することも、[Workflow](../workflows/) で複数の分離コンテキストに分割して相関エラーを抑えることも、LLM 不要の Applet Action で決定論的な同期・点検を定期実行することもできます。どの実行経路でも Meta Ankole と受信 Signal が最新の文脈を供給し、Principal と AuthZ が操作境界を守り、得られた結果が次の業務へと還流します。

## 現在のステータス

Ankole は、本番稼働するエンタープライズ向けデジタル本社および Agent Harness です。Elixir コントロールプレーン、Pod ワークスペース、Function Runtime（`ankole-function-runtime`）、Agent Computer Worker、Rust カーネル、Meta Ankole、統合 Connectors、運用 Console をすべて自社インフラ上にセルフホストできます。中核コードと主要ステートマシンには形式検証を適用し、メッセージルーティング・Drive ACL・障害復旧・並行制御・アップグレードを網羅する E2E テストを継続実行しています。

なお、Ankole にはパブリック API の後方互換性保証はなく、リリース時に破壊的変更が含まれる場合があります。

## 次のステップ

デプロイを始めるには [クイックスタート](../quickstart/) に進んでください。各コンポーネントの連携構造については [アーキテクチャ概要](../architecture/) を参照してください。
