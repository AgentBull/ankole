# BullX — AI Colleagues と並んで働く AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX は初期開発段階です。一部の機能は今後のリリースで対応予定です。**

BullX は、自律性を持つ AI Colleague と並んで働くための AgentOS です。

Elixir/OTP、PostgreSQL、Redis 上に構築され、enterprise department、small team、one-person company のいずれにも同じ中核モデルで適用できます。

Chatbot は LLM を会話可能にしました。[OpenClaw](https://grokipedia.com/page/OpenClaw) と [Hermes-Agent](https://hermes-agent.nousresearch.com/docs/user-stories) の世代は、Agent に手を与えました。channels、tools、skills、shell/browser、memory files、SubAgent、scheduled work です。[Dify](https://docs.dify.ai/en/use-dify/getting-started/key-concepts)、RPA、RAG workflow builder は、AI を specific business app として package しやすくしました。BullX が目指すのはその次です。AI Colleague が audit、recovery、governance、learning が可能な operating model の中で長期的に work を担うことです。

BullX の中心にあるのは、RAG customer-support bot でも、指示を待つ digital assistant でもなく、AI Colleague としての Agent です。BullX Agent は long-term mission、KPI/OKR-style goals、responsibility、long-term memory、permission、outbound identity を持ち、長い時間軸で働き、人間や他の Agent と協働し、trajectory data から改善します。

BullX は「もう一つの chat interface」を目指していません。AI Colleague を durable work system に組み込みます。

- **Agent** は long-term mission、responsibility、permission、memory、outbound identity、KPI/OKR-style goals を持ちます。
- reactive **Workflow** は、digital work が現実世界の Signal にどう反応するかを記述します。
- **Segment** は実行ごとの明確な boundary を作り、work の record、recovery、audit、handoff を可能にします。見えない runtime state に依存しません。
- **Principal**、**Budget**、human collaboration path により、責任・費用・承認を高リスク action の前に明示します。
- **Capability** は model、tool、browser、sandbox、messaging channel、API、外部 agent harness を公開しますが、実行権限を prompt の中に隠しません。
- **Brain** は long-term memory と reasoning world model を提供します。raw vector log でも、巨大化する Markdown memory file でも、最初から完全に predefined された ontology でもなく、conversation、event、action、outcome から抽出・修正・統合される知識です。

## Three Models, One Distinction

多くの system が agent や digital worker を名乗るようになりましたが、最適化している対象は違います。

- **OpenClaw / Hermes-style assistants** は prompt-driven Agentic Loop です。personal assistance、tool use、channel integration、cron、memory files、skills、SubAgent が得意です。中心にあるのは、prompt、schedule、message によって動く assistant session です。
- **Dify / RPA / RAG workflow digital workers** は app-driven または workflow-driven automation です。customer-service bot、BI report bot、invoice review bot、document extraction など、bounded で repeatable な pipeline に向いています。
- **BullX AI Colleagues** は mission-driven work subject です。mission は one-off task ではなく、KPI や OKR に近い long-term objective です。permissions、budgets、memory、outbound identity、responsibility を持ちます。world を observe し、何が重要かを判断し、人間や他の Agent と協働し、trajectory data から改善します。

| Dimension | OpenClaw / Hermes-style assistant | Dify / RPA / RAG workflow worker | BullX AI Colleague |
| --- | --- | --- | --- |
| Primary unit | Agentic Loop または assistant session。 | App、bot、RPA flow、workflow run。 | long-term mission、responsibility、Work、Workflow context を持つ Agent。 |
| Autonomy | prompt、message、cron、user-configured task に反応する。 | specific business scenario の定義済み process を実行する。 | signal を観察し、priority を決め、help を求め、delegate し、long-term objective を進める。 |
| Actions | Tool call、shell/browser work、message、file、SubAgent。 | form fill、API call、extraction、routing、approval、report generation。 | 明示的な side effect、recovery、audit を持つ governed Capability と Workflow step。 |
| Memory and reasoning | Session memory、markdown files、skill notes、external memory layer。 | RAG knowledge base、workflow variables、app-specific state。 | conversation、event、action、relationship、outcome、domain object から成長する reasoning world model としての Brain。 |
| Self-evolution | past session から新しい skill や notes を学ぶ。 | workflow や knowledge base が手動更新されたときに改善する。 | trajectory data から planning、Skill、policy、future execution を改善する。 |
| Permissions and budgets | 多くは tool policy、model config、local runtime control。 | app credential、node permission、rate limit、workflow setting。 | Principal identity、delegated authority、Budget、outbound identity、audit boundary。 |
| Human collaboration | approval prompt、DM gate、manual confirmation が多い。 | specific process 内の approval node または manual review step。 | human は manager、peer、assignee になれる。approval、correction、escalation、takeover、missing context の提供、現実世界の help、Agent から割り当てられた task を担う。 |
| External signals | channel、cron、webhook、integration が assistant loop に入る。 | trigger が predefined app または workflow を起動する。 | Signal が Workflow を開始または継続し、domain object に correlate し、long-running Work を更新する。 |
| Accountability | transcript と tool history が session 内の出来事を説明する。 | workflow log が 1 回の app run を説明する。 | product fact が誰が行動し、誰が承認し、どの Budget を使い、何が変わり、trajectory data が次の振る舞いをどう改善するかを記録する。 |

## Why BullX

BullX は earlier agent systems の有用な surface を保ちます。channels、tools、Skills、sandboxes、browsers、SubAgents、schedules、conversational entry points です。違いは product truth の置き場所です。BullX では、durable work は assistant session や workflow run log だけでなく、Workflow、Principal、Budget、Brain、domain record、trajectory data に属します。

BullX は Palantir-style ontology program とも異なります。Brain は ontology と semantic web に着想を得ていますが、BullX は expert が complete business graph を先に定義することを前提にしません。world model は work の中で育ちます。conversation、Signal、domain record、decision、handoff、correction、outcome を通じて、AI Colleague は business、industry、company context、そして人が実際に仕事を進める tacit knowledge に徐々に詳しくなります。

BullX が目指すものは「より良い bot」でも「より賢い workflow app」でもありません。AI Colleague が observe、decide、delegate、wait、ask、spend、remember、act でき、その全体が product level で accountable であるための operating system です。

## Product Feel

**Group chat can be observed without adding noise.** Customer-success Agent は group conversation から risk を検出し、Work を作成し、account owner に private notification を送り、group にはデフォルトで返信しません。

**One signal can start real process logic.** 顧客の budget freeze message は、同じ Workflow graph 内で customer-success analysis、finance risk review、ignored path に branch できます。

**Memory can include the world, not only the chat.** Research Agent は、会話だけでなく market、policy、product、operation、external event を同じ context として理解し、actual work から育った ontology-backed world model から retrieve します。

**The world model can mature like a human colleague.** BullX Agent は team に加わったあと、business、industry、internal norms、recurring exceptions、tacit knowledge に徐々に詳しくなるべきです。organization が day one にすべてを model する必要はありません。

**Agents can own missions, not just tasks.** Coding Agent、research Agent、customer-success Agent は、複数の interaction にまたがって働き、人間や他の Agent と協働し、trajectory data から次の planning を改善します。

**Humans can be managers, peers, or assignees.** human は Agent を approve / correct でき、peer として一緒に進め、case を take over し、現実世界の context を補い、また Agent から task を受け取ることもできます。たとえばオフラインで事実確認をする、login QR code を scan する、などです。

**High-risk work can be gated.** Customer-facing、financial、legal、permission-changing、irreversible な外部 action は、実際の side effect の前に approval または policy gate を通るべきです。

## Project Status

現在の公開 repository には BullX の foundation が含まれています。

- Elixir/OTP application boot と supervision
- PostgreSQL Repo と dynamic configuration
- UUIDv7 と native helper boundary
- i18n catalog infrastructure
- Phoenix、Inertia、Rsbuild、UIKit、setup/session/console foundation
- health endpoints と OpenAPI description plumbing
- `packages/` 以下の再利用可能な独立パッケージ

完全な AI Colleague product は、この foundation の上で段階的に構築されます。

深い technical model は [docs/Architecture.md](./docs/Architecture.md) を読んでください。

## Getting Started

**Prerequisites:** Elixir 1.19+, PostgreSQL, Bun

PostgreSQL が起動しており、`.env.dev` または `.env.local` の `DATABASE_URL` が利用可能なデータベースを指していることを確認してください。

```sh
# Elixir dependencies, JS dependencies, database, and assets
bun setup

# Start Phoenix and the Rsbuild development asset server
bun dev
```

`http://localhost:4000` を開きます。現在の app shell は `/` を `/setup` にリダイレクトします。

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
