# Ankole - 共有 AI 同僚のためのオープン AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[English](./README.md) | [简体中文](./README.zh-Hans.md)

Ankole は、共有 AI 同僚を動かすための、オープンソースでセルフホスト可能な AgentOS です。

目標は、AI の仕事を個人用チャット欄から出し、仕事が実際に起きている場所へ置くことです。チャンネル、リポジトリ、スケジュール、ダッシュボード、社内システム、長期プロジェクトの文脈がその場所です。Ankole agent は、自分の identity、memory、permission、tool、workspace、responsibility boundary を持つべきです。

[Claude Tag](https://claude.com/product/tag) は分かりやすい公開参照です。Slack thread で AI を tag し、共有文脈を読ませ、組織の tools を使わせ、channel context を記憶し、時間のかかる work を follow up させる。Ankole はその pattern をより open で広い形にします。Slack だけでも、Claude だけでも、1 つの agent だけでも、vendor-owned context でもありません。

Ankole が向いているのは、答えだけでなく責任者が必要な仕事です。よい Ankole role には見える結果があります。Code が merge される、report が shipped される、customer issue が handled される、alert が triaged される、market change が noticed される、backlog が worked down される、といった結果です。

## Ankole が加えるもの

- **個人チャットではなく共有作業。** Agent は shared channel や provider context に参加し、複数の人間が同じ work を observe、steer、continue できます。
- **永続 ID。** 人間と agent は Principal として表現され、external identities、groups、permission grants を持ちます。
- **複数の入力元。** IM、webhook、scheduled reminder、internal system、将来の provider adapter は normalized signal input になります。
- **複数の agent。** 1 つの Ankole 環境で、異なる mission、access、tools、memory、outbound identity を持つ複数の agent を動かせます。
- **Session actors.** 長期実行単位は `actor_id = {agent_id, session_id}` です。Session は context、workspace state、steering、cancel、recovery が交わる場所です。
- **自分の文脈。** Conversation、model turn、summary、signal projection、decision、correction、将来の domain record は自分の infrastructure に残ります。
- **運用者による制御。** Access、configuration、plugin activation、actor lease、outbox side effect、audit surface は Ankole を運用する側が管理します。

## プロダクト形態

Ankole は、次のような workflow を自然にするためのものです。

- coding agent が issue を監視し、bug を再現し、code を変更し、draft PR を開き、人間の decision が必要な点を報告する。
- customer-success agent が shared group chat を観察し、重要な facts を記録し、work state を更新し、必要な時だけ private escalation する。
- research agent が market、policy、competitor、internal notes を監視し、重要な変化があった時に follow up する。
- QA agent が test backlog を進め、evidence を集め、context 付きの failure を review に渡す。
- operations agent が alert を監視し、runbook を準備し、risk の高い action の前に approval を求める。

共通する形は「この質問に答える」ではなく、「この seat を持ち、利用可能な context を使い、結果で評価される」です。

## Actor Runtime

Ankole は、長時間の AI work のための actor-oriented runtime です。各 active session は addressable virtual actor です。Wake、message receive、checkpoint、stream progress、hibernate、recover、continue ができ、agent を単なる HTTP request や queue job として扱いません。

Runtime は 5 つの technical bets に基づきます。

- **Virtual Actors for AI work.** Session は address、state、mailbox、lifecycle、recovery path を持つ work identity であり、散らばった background work ではありません。
- **OTP Supervision Trees as failure domains.** 1 つの agent が hang、timeout、crash しても、Ankole はその branch を isolate または restart し、環境全体の failure に広げません。
- **ZeroMQ Activation Fabric for live control.** Wakeup、steering、checkpoint、streaming、backpressure は low-latency routing layer を通り、agent が作業中でも誘導や介入ができます。
- **Agent Computer as execution substrate.** LLM loop、tools、MCP servers、files、terminal state、streaming output は、workspace に近い Bun + TypeScript computer 内で動きます。
- **Durable Ledger for recovery and audit.** Mailbox、turn、reminder、decision、committed side effects は process より長く残ります。Streaming は progress であり、commit された work が truth です。

ユーザーと運用者にとっての約束は単純です。Agent は数時間から数日働き続け、実行中に新しい input を受け取り、独立して fail し、context を保ったまま recover し、side effect を説明可能にします。Runtime の詳しい考え方は [なぜ OTP はより良いマルチエージェント・オーケストレーションのランタイムなのか](https://ding.ee/ja-JP/why-otp-is-a-better-runtime-for-multi-agent-orchestration/) にまとめています。

これが Ankole の技術的な賭けです。Actor model は long-lived work identity と lifecycle を支え、OTP は failure semantics を支え、ZeroMQ は live activation を支え、Agent Computer は local execution を支えます。Ankole は chatbot backend というより、AI work のための distributed operating system に近いものです。

## 現在のリポジトリ

このリポジトリは Ankole の初期 control-plane and runtime foundation です。まだ polished end-user distribution ではありません。

- `app/control_plane` - Principal/AuthZ、AppConfigure、plugins、SignalsGateway、setup、console、web shell のための Phoenix control plane。
- `app/kernel` - crypto、hashing、identifier、policy helper など runtime-neutral mechanism のための shared native foundation。
- `app/ai_proxy` - LLM-provider-adjacent runtime work のための Bun/Elysia surface。
- `app/webapps` - Phoenix shell から mount される Rspack-powered frontend applications。
- `libs/uikit` - Ankole webapps で共有する UI primitives。
- `libs/feishu_openapi` - local Lark/Feishu OpenAPI client library。
- `plugins` と `internals/plugins` - trusted first-party Elixir plugins。Plugin は installation-global、default-on で、global disable list により無効化します。
- `docs/design-docs` - principal identity、authorization、configuration、signals、plugins、provider adapters の現在の design docs。

SignalsGateway は provider ingress layer です。Ankole が chat、webhook、provider event を観測しつつ、外部 source facts と agent execution を混同しないための層です。Signal は actor input になり、actor scheduling と execution は runtime に残ります。

## 開発

Ankole は workspace scripts に Bun を使い、control plane に Elixir/Phoenix を使います。

```shell
bun install

# Local support services and workspace helpers
bun run kit --help
bun run services:start
bun run services:status

# Control plane
bun run control-plane:setup
bun run control-plane:dev
bun run control-plane:test

# Bun packages
bun run ai-proxy:dev
bun run ai-proxy:test
bun run webapps:build
bun run feishu-openapi:test
```

Workspace が速く動いている間は、package-local validation を優先します。

```shell
bun run --filter @ankole/control-plane test
bun run --filter @ankole/ai-proxy test
bun run --filter @ankole/webapps type-check
bun run --filter @ankole/feishu-openapi test
```

Production bootstrap configuration は `DATABASE_URL`、`SECRET_KEY_BASE`、`REDIS_URL` のような標準 infrastructure 名を使います。Runtime application configuration は process-local environment variables ではなく、Ankole の PostgreSQL-backed AppConfigure surface に属します。
