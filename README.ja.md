# BullX — Next Generation AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX は初期開発段階です。このブランチは大規模な削除整理後の infra shell であり、具体的なプロダクト詳細は design doc を通じて変わります。**

BullX は、Elixir/OTP と PostgreSQL 上に構築された general-purpose AgentOS です。長時間続くデジタルワークを対象にしており、企業チーム、小規模な運営組織、OPC（one-person company）のいずれにも同じ中核モデルで適用できます。再開可能な DAG workflow が AI Agent、integration、明示的な Action Node、memory、記録された結果を時間をかけて調整します。

BullX は単なるチャット bot フレームワークでも、LLM tool runner だけでもありません。長期的な目標は、永続 workflow の中で AI Agent と他の Action Node が実際の仕事に安全に参加するための operating system です。

## Current State

このブランチは意図的にインフラの外枠だけを残しています。

- Elixir/OTP application boot と supervision
- PostgreSQL Repo と dynamic configuration
- UUIDv7 と native helper boundary
- 空のプロダクト文言を持つ i18n catalog infrastructure
- Phoenix、Inertia、Rsbuild、UIKit、placeholder の setup SPA
- health endpoints と OpenAPI description plumbing
- `packages/` 以下の再利用可能な独立パッケージ

削除済みの product surface を断片的に戻さず、新しいプロダクト挙動は design doc から導入してください。

## Product Direction

BullX は streaming support を持つ再開可能な DAG workflow を中心に整理されます。具体的な table design、process topology、queue name、provider adapter はまだ確定していません。

- **Installation** — 一つの BullX deployment と operating domain。BullX は汎用 AgentOS ですが、SaaS multi-tenancy をデフォルトの product boundary とはみなしません。
- **Principal** — authorization、audit、responsibility の対象となる内部主体。human、Agent、service、system actor はすべて Principal です。
- **Workflow** — Signal Trigger と Action Node からなる再開可能な directed acyclic graph。永続 workflow state は、retry、pause、resume、process restart 後の recovery に十分な進捗を記録します。
- **Signal Trigger** — workflow の開始点または ingress point で、何が起きたかを正規化します。Provider adapter、webhook、schedule、routing は、独立した product layer ではなく Signal Trigger として扱います。
- **Action Node** — workflow 内で work を実行する step。transform、approval、notification、blackhole などの非 AI behavior は Action Node であり、Agent ではありません。
- **Sink Action Node** — `sink=true` を持つ Action Node。その branch を終端するため、その下に downstream Action Node は置けません。blackhole/drop branch も Sink Action Node です。
- **Streaming Input / Streaming Output** — node ごとの flag。Streaming Input は上流の incremental data を消費できることを、Streaming Output は下流へ incremental data を出せることを意味します。
- **Bidirectional Trigger / Reply to Trigger** — Signal Trigger が `bidirectional=true` の場合、DAG 内で `Reply to Trigger` という特別な Action Node を使えます。これは常に `sink=true` です。
- **Agent** — AI Agent であり、workflow 内で実行されるときは Action Node として表現されます。identity、responsibility、memory、allowed provider、permission、outbound identity、KPI を持ちますが、すべての executable actor の汎称ではありません。
- **Work** — Workflow run をまたいで持続する永続的な責任。1 回の Workflow run は、Work を create・advance・pause・resume・complete し得る 1 回の実行です。
- **Brain** — 将来の ontology と reasoning-memory layer。raw vector log ではなく、object、relationship、perspective、engram、consolidation を中心にします。

## User Stories

### Group Chatを見守るが発言しない

Messaging Signal Trigger は顧客グループの event から workflow を開始できます。Customer-success Agent Action Node はリスクを分析し、Work を作成または更新し、担当者へ個別に通知できます。デフォルトではグループ内で発言しません。

### 一つのSignal Triggerから複数Branchを開始する

同じ外部イベントでも、Agent ごとに意味が違います。顧客の予算凍結に関するメッセージは、CustomerSuccessAgent branch、FinanceAgent branch、無関係な branch の `sink=true` blackhole Sink Action Node へ fan out できます。

### 会話と外部イベントを一緒に記憶する

Research Agent は、ユーザーとの会話と市場・政策・運用イベントを同じ記憶システムで扱えます。将来の回答では、過去チャットの全文検索だけでなく、ontology-backed world model から context を取得するべきです。

### 結果から改善する

Agent Action Node は繰り返しの結果から学ぶべきです。Coding Agent が fixture context 不足で何度も失敗するなら、次の Work planning では patch 作成前に fixture context を集めるべきです。

### リスクの高い外部行動をGateする

Customer-facing、financial、legal、その他 sensitive な外部 action は、side effect を持つ Action Node が実行される前に、明示的な approval または policy-gate Action Node を通るべきです。

## Design Invariants

- PostgreSQL は永続的な fact source です。
- process-local state は一時的で、再構築可能でなければなりません。
- process は failure boundary であり、domain noun ではありません。
- Workflow は再開可能な DAG であり、linear chat session ではありません。
- Provider adapter と routing は Signal Trigger として扱います。
- Action Node は Streaming Input、Streaming Output、またはその両方を support するか宣言します。
- Sink Action Node は終端です。`sink=true` の下に downstream Action Node は置けません。
- `Reply to Trigger` は `bidirectional=true` の Signal Trigger にだけ存在し、常に sink です。
- Reliability は durable checkpoint、retry、idempotent node contract、operator recovery から得られるものであり、global な strict exactly-once guarantee ではありません。
- 外部 side effect を持つ Action Node は明示的な workflow node であり、隠れた raw tool call ではありません。
- リスクの高い外部 write や message は、実行前に明示的な approval または policy-gate Action Node を通らなければなりません。
- 重要な挙動は audit、explanation、recovery が可能でなければなりません。
- Memory は非構造ログとして蓄積するのではなく、reasoning と consolidation を通じて進化するべきです。

## Development

**Prerequisites:** Elixir 1.19+, PostgreSQL, Bun

PostgreSQL が起動しており、`.env.dev` または `.env.local` の `DATABASE_URL` が利用可能なデータベースを指していることを確認してください。

```sh
# Elixir dependencies, JS dependencies, database, and assets
bun setup

# Start Phoenix and the Rsbuild development asset server
bun dev
```

`http://localhost:4000` を開きます。現在の app shell は `/` を `/setup` にリダイレクトしますが、このブランチでは placeholder です。

開発環境では Phoenix が Rsbuild を endpoint watcher として起動します。ブラウザ入口は `http://localhost:4000` のままで、Rsbuild は `http://localhost:5173` から React/Inertia の hot reload を提供します。ポートが使われている場合は、`.env.local` に `PORT` と `RSBUILD_PORT` を設定します。例: `PORT=4001`、`RSBUILD_PORT=5174`。

Useful project commands:

```sh
# Install/update JS dependencies
bun install

# Run the full project check used before committing
bun precommit

# Run frontend tests and cross-language lint checks
bun run test
bun run lint
```

## Rsbuild Asset Builds

React/Inertia の entry は `webui/src/app.jsx`、SPA pages は `webui/src/apps/` 以下にあります。deployable assets では、Rsbuild が `priv/static/assets/.rsbuild/manifest.json` を出力し、Phoenix は development 以外でその manifest から script と style を解決します。

Bun は repository root から実行します。Rsbuild は application source に `webui/src/`、Phoenix CSS entry に `assets/css/` を使います。

```sh
# Build Rsbuild assets and manifest
mix assets.build

# Build production assets, including digests
mix assets.deploy
```

`mix assets.deploy` は compilation、Rsbuild build、`phx.digest` を実行します。production release の前に実行してください。

**Production:**

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/bullx/bin/bullx start
```

## Environment Files

BullX は repository root から dotenv files を読み込みます。後から読み込まれる file が先の値を上書きし、すでに存在する OS environment variables は dotenv の値より優先されます。

| Environment | Load order |
|---|---|
| Development | `.env` -> `.env.dev` -> `.env.local` |
| Test | `.env` -> `.env.test` |
| Production | `.env` -> `.env.prod` |

`.env.local` は gitignored で、machine-specific secrets のためのものです。`.env`、`.env.dev`、`.env.test` は shared non-secret team defaults として commit できます。
