# BullX — Next Generation AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX は初期開発段階です。このブランチは大規模な削除整理後の infra shell であり、具体的なプロダクト詳細は design doc を通じて変わります。**

BullX は、Elixir/OTP と PostgreSQL 上に構築された general-purpose AgentOS です。長時間続くデジタルワークを対象にしており、企業チーム、小規模な運営組織、OPC（one-person company）のいずれにも同じ中核モデルで適用できます。Agent が Signal を認識し、Work に責任を持ち、統制された Capability を通じて行動し、Outcome を記憶し、時間とともに改善します。

BullX は単なるチャット bot フレームワークでも、LLM tool runner だけでもありません。長期的な目標は、永続的な Agent が実際の仕事に安全に参加するための operating system です。

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

BullX は少数の永続概念を中心に整理されます。具体的な table design、process topology、queue name、provider adapter はまだ確定していません。

- **Installation** — 一つの BullX deployment と operating domain。BullX は汎用 AgentOS ですが、SaaS multi-tenancy をデフォルトの product boundary とはみなしません。
- **Principal** — authorization、audit、responsibility の対象となる内部主体。human、Agent、service、system actor はすべて Principal です。
- **Agent** — identity、responsibility、memory、capability、permission、outbound identity、KPI を持つ永続的な work subject。Agent は自動的に LLM process や chat bot を意味しません。
- **Signal** — 何かが起きたことを正規化して表すもの。Signal は task ではありません。
- **Admission** — Signal を Agent の attention space に入れるかどうかの判断。owner、observer、reviewer、delegate、subscriber、blocked などの関係を記録します。
- **Work / Mission** — 長期的な責任。Mission は永続的な goal、Work は具体的な commitment です。
- **Capability** — Agent が使える統制された能力。reasoning、browser、code、messaging、data、memory、approval などの provider に支えられます。
- **Intent / Governance / Effect** — Agent は Intent を提案し、Governance が Effect へ進めるか判断し、Effect が Outcome と audit record を生みます。
- **Brain** — 将来の ontology と reasoning-memory layer。raw vector log ではなく、object、relationship、perspective、engram、consolidation を中心にします。

## User Stories

### Group Chatを見守るが発言しない

Customer-success Agent は顧客グループを見守り、リスク Signal を静かに処理し、Work を作成または更新し、担当者へ個別に通知できます。デフォルトではグループ内で発言しません。

### 一つのSignalを複数AgentへAdmissionする

同じ外部イベントでも、Agent ごとに意味が違います。顧客の予算凍結に関するメッセージは、CustomerSuccessAgent には owner、FinanceAgent には observer、無関係な Agent には blocked になり得ます。

### 会話と外部イベントを一緒に記憶する

Research Agent は、ユーザーとの会話と市場・政策・運用イベントを同じ記憶システムで扱えます。将来の回答では、過去チャットの全文検索だけでなく、ontology-backed world model から context を取得するべきです。

### Outcomeから改善する

Agent は繰り返しの結果から学ぶべきです。Coding Agent が fixture context 不足で何度も失敗するなら、次の Work planning では patch 作成前に fixture context を集めるべきです。

### リスクの高い外部行動を統制する

Agent は customer-facing、financial、legal、その他リスクの高い Effect を直接実行すべきではありません。まず Intent を作り、Governance がリスクと承認要件を判断し、承認された Intent だけが外部 Effect になります。

## Design Invariants

- PostgreSQL は永続的な fact source です。
- process-local state は一時的で、再構築可能でなければなりません。
- process は failure boundary であり、domain noun ではありません。
- Signal は何が起きたかを表し、Admission は誰が見るべきかを決めます。
- Agent は処理しても返信しないことがあります。
- Capability は統制された能力であり、裸の tool call ではありません。
- Intent は Effect より先に存在します。
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
