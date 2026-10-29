# Contributing to Ankole

Thank you for contributing to Ankole! This guide walks both human contributors and coding agents through setting up, testing, and changing the repository, assuming no prior background in Ankole, Elixir, Phoenix, Ecto, Rust, or OTP.

> [!WARNING]
> Ankole is under active development. Public APIs do not yet carry a backwards-compatibility contract, so interfaces and subsystem boundaries can change between releases.

A **site** is one complete Ankole deployment. A single site can host multiple **tenants**, each owning its own people, Agents, Company Brain, and external integrations. Site operators manage shared providers and cluster infrastructure through the site administration Console at `/site-admin-console` (or the custom absolute path configured in `ANKOLE_SITE_ADMIN_CONSOLE_PATH` before startup). Active Human users sign in on their tenant's subdomain (locally, `http://<tenant-slug>.ankole.localhost:4000/`) through that tenant's configured identity providers, or initiate login from an OIDC application.

## Source builds

`ANKOLE_EDITION=foss|saas` selects which edition to build. Even when a private `internals/` checkout is present, builds default to `foss`: the FOSS build never compiles private modules, reads private configuration, or installs private migrations. Building with `ANKOLE_EDITION=saas` requires the matching `internals/` checkout and fails immediately if any required file or module is missing.

Both editions share one Mix project, one `:ankole` OTP application, one `Repo`, and one control-plane database, while keeping isolated `_build/foss` and `_build/saas` build trees (including Vite bundles and generated locale catalogs). Assembling a release copies only the selected edition's assets and catalogs into the release directory, so a packaged release runs without a source checkout. Build tasks bypass Turbo artifact caching, while static and test checks include the active edition in their cache keys.

A `saas` build expects these inputs under `internals/`:

- **`internals/control_plane/config.exs`** — declares the HTTP entry point, `Host` policy, `AppConfigure` definitions module, and trusted site identity sources.
- **`internals/control_plane/lib/`** — provides distinct private Elixir modules without redefining public modules or starting a second OTP application.
- **`internals/control_plane/test/test_helper.exs`** — configures private tests. Mix runs both public and private test suites together, compiling test-support modules only in `:test`.
- **`internals/webapps/entries.json`** — defines an `entries` map of unique private entry names and an optional `overrides` map wrapping existing public entries (values are relative source paths). Private frontend code shares the public webapp dependencies via a relative `node_modules` symlink created automatically by Mix, Vite, type-checking, and Bun test preparation (plain entry reads do not create it; concurrent tasks safely converge on the same target, replace stale symlinks, and reject standalone `node_modules` directories). Linting, type checks, and tests cover both public and private sources.
- **`internals/locales/`** — supplies private TOML translation catalogs that build preparation merges with `app/locales/` into generated JSON (duplicate message keys fail the build). Phoenix, Vite dev/prod builds, and Bun tests all read that single merged output.
- **`internals/control_plane/priv/repo/migrations/`** — supplies private Ecto migrations.

`Ankole.Migrations` feeds the full selected migration set to `mix ecto.migrate`, `mix ecto.migrations`, `mix ecto.rollback`, and `Ankole.Release.migrate/0`. Migration timestamps, filenames, and module names must be globally unique across both public and private directories (including historical migrations that have already run), and data-migration queries must select only columns that exist at that point in the migration timeline. SaaS releases package private migrations under `priv/repo/internal_migrations` alongside public migrations, sharing the same `schema_migrations` table. Switching back from `saas` to `foss` does not automatically roll back private schema changes.

To verify edition builds from `app/control_plane`:

```bash
mix test
ANKOLE_EDITION=saas mix test
MIX_TEST_PARTITION=edition_build mix test integration/edition_build_test.exs --trace
```

With `ANKOLE_EDITION=saas`, `mix test` excludes the tests tagged `:foss_sign_in`. These tests cover the Pod sign-in pages, and the SaaS edition signs in on the accounts host instead.

`edition_build_test.exs` spins up a labeled private fixture inside a temporary checkout to verify FOSS isolation, SaaS compilation and assets, private test discovery, fresh and upgraded databases, rollbacks, and a standalone release—exercising built Pod and Auth webapps over real HTTPS sessions, Principal authorization, generated API clients, and local SMTP (it tests build plumbing rather than certifying a commercial SaaS product). Before running it, install Chromium with `bunx playwright install chromium` and ensure `openssl` is on `PATH` for temporary TLS certificates.

Docker builds for the control plane use Cargo to compile the native Rust Kernel and Torque libraries. To build a SaaS image from the public `Dockerfile`, pass `internals/` as a named build context:

```bash
docker build -f app/control_plane/Dockerfile \
  --build-arg ANKOLE_EDITION=saas \
  --build-context ankole-internals=./internals .
```

(Note: while an internal resource image layer can bundle private Agent templates or Skills onto an existing image, copying files alone never compiles SaaS backend or frontend code—always run a `saas` source build for code changes.)

## What a successful setup means

A full local development setup is complete only when all five of these hold:

1. `bun`, `elixir`, `rustc`, `docker`, and `docker compose` all work in a fresh terminal session.
2. Both devkit containers (`PostgreSQL` and `Function Runtime`) report healthy, and control-plane Ecto migrations have completed.
3. `bun dev` serves the Phoenix control plane, Web Console, and Vite assets. Creating an Agent triggers Worker startup; after an idle Worker stops, environment tools or Codex Jobs wake it on demand, whereas pure Q&A turns answer immediately without waiting on a Worker.
4. The initial root administrator can sign in, and an LLM provider, Agent, and Signal binding are configured.
5. Sending a live message in Feishu/Lark reaches the Agent and posts the expected reply back to the chat.

Documentation-only or isolated package changes usually do not require completing the live Feishu smoke test—just state clearly which stage you verified and which stages you skipped.

## How a coding agent should guide a human

When pairing on setup, divide responsibilities along trust boundaries:

- **The coding agent** handles safe terminal work: inspecting the repo, installing toolchains and packages, starting Docker services, running verification commands, reading non-sensitive logs, and pinpointing the first failing boundary.
- **The human** handles credentials and external account actions: entering `sudo` passwords or API keys, completing browser logins and OAuth consent screens, creating/publishing the Feishu test app, and approving any destructive reset.

Before running commands, the coding agent must:

1. Read both this guide and [`AGENTS.md`](AGENTS.md) completely.
2. Verify that its working directory is the repository root.
3. Run `git status --short` and leave unrelated worktree diffs untouched.
4. Advance through the numbered setup stages in order, verifying each stage before moving on.

The agent must pause and hand off whenever the human needs to:

- enter a system password or secret credential;
- complete a browser sign-in, OAuth consent flow, or external admin console step;
- choose a model provider, model tier, or external app visibility policy;
- approve dropping a database, deleting a Docker volume, or discarding local files.

Never dump `env`, open secret files without a specific reason, paste credentials into chat, or embed secrets in shell commands that land in shell history—enter secrets directly into the Console's masked fields instead. And if a full end-to-end setup fails partway through, do not reframe partial progress as full completion: name the first broken stage, show the error evidence, propose the next safe step, and list what remains unverified.

## Understand the local system

You do not need to learn Elixir, Rust, and Bun internals up front—the root `package.json` scripts automatically switch directories and coordinate every runtime.

| Component | Role | Source | Local address / container |
| --- | --- | --- | --- |
| PostgreSQL | Stores all authoritative control-plane state and dev Base shards | Devkit Compose service | `localhost:5433` |
| Function Runtime | Executes stateless Applet backends and deterministic TypeScript steps | `app/function_runtime` | `localhost:5435` |
| Control Plane | Serves Setup, Console APIs, durable workflows, and commit authority | `app/control_plane` | `http://ankole.localhost:4000` |
| Webapps | React apps for Setup, Auth, Pod, and Console | `app/webapps` | Vite on `localhost:3035` (proxied via `:4000`) |
| Agent Computer | Executes Worker environment tools, Codex, and materialized Skills | `app/agent_computer` | One Docker container per Agent (`ankole.installation=dev`) |
| Kernel | Shared native Rust primitives and HTTP/WebSocket transport | `app/kernel` | Loaded into Elixir via Rustler and browser daemon via N-API |
| RuntimeFabric | Multiplexes live control-plane-to-Worker RPCs over a Phoenix Channel | Control Plane | `ws://localhost:4000/runtime-fabric/worker` |

### Elixir in five minutes

If Elixir is new to you: `mix` is the build and task tool, **Phoenix** is the HTTP/WebSocket web framework, **Ecto** handles database queries and schema migrations, **ExUnit** runs tests, and **OTP** supervises fault-tolerant background processes. Regular source files end in `.ex`, while tests, scripts, and configs end in `.exs`.

Control-plane domain logic, web routes, configuration, migrations, and tests all live under `app/control_plane/`, whose Mix project also compiles first-party plugins from `plugins/*/lib` (along with their provider clients) into the same `:ankole` application. Stick to root `bun run ...` scripts unless a section explicitly tells you to run `mix` inside `app/control_plane`.

## 1. Get the repository and choose an environment

If the repository is not already present, clone your fork or the upstream repository:

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole
git status --short
```

All commands below run from this repository root unless a command explicitly changes directories.

### Local macOS, Linux, or WSL2

Use macOS or Linux. On Windows, use WSL2; the environment installer does not support native Windows shells.

You need:

- an account that can install system packages, because setup may request `sudo`;
- a stable network connection for toolchains, packages, and Docker images;
- Docker Desktop on macOS, or Docker Engine with Compose on Linux;
- an LLM provider API key for the end-to-end test;
- a Feishu account that can create an enterprise custom app for the full integration test.

The financial-data MCP key is optional. It is required only when you want to exercise that integration.

### GitHub Codespaces for code and test work

The repository's `.devcontainer/` installs the Bun, Elixir/Erlang, and Rust toolchains, enables Docker-in-Docker, forwards the local ports, and runs `bun install`.

The configured minimum is 4 CPU cores, 8 GB of memory, and 32 GB of storage. After creation, continue with the verification commands in the next section.

The exact Feishu walkthrough below assumes a browser and Ankole running on the same machine at `localhost:4000`.

Codespaces uses a forwarded HTTPS origin. It is suitable for code, build, and test work, but the Feishu callback must be adapted and verified before it can satisfy the documented end-to-end result.

Use the local macOS, Linux, or WSL2 route when the goal is to reproduce the baseline Feishu setup without changing callback URLs.

**Stage 1 is complete when the repository is open at its root in the chosen environment and the required accounts and keys are available to the human.**

## 2. Install and verify the system tools

On a local machine, first inspect the installer if desired:

```bash
bash tools/devkit/scripts/env-setup.sh --dry-run
```

Then run it:

```bash
bash tools/devkit/scripts/env-setup.sh
```

The script installs system build packages, Docker, the Rust toolchain pinned in `rust-toolchain.toml` with `rustfmt` and `clippy`, `sccache`, the repository's Elixir/Erlang toolchain, and the Bun version pinned by the repository. Whenever `sccache` is on `PATH`, devkit, Rustler NIF builds, and Kernel scripts automatically wrap Cargo with a local SSD cache; machines without `sccache` (or with `ANKOLE_SCCACHE=0`) run standard Cargo without extra configuration.

When it finishes:

1. Open a new terminal so the PATH changes take effect.
2. On macOS, start Docker Desktop and wait until its daemon is ready.
3. On Linux, log out and back in if the script added your user to the `docker` group.
4. Return to the repository root and run:

```bash
bun --version
elixir --version
rustc --version
cargo clippy --version
docker compose version
docker info
```

`bun --version` must match the `packageManager` version in `package.json`, and `rustc --version` must match the channel in `rust-toolchain.toml`. Every other command must exit successfully, and `docker info` must connect to the daemon.

Do not continue while `docker info` fails. Fix Docker Desktop startup or Linux group permissions first.

**Stage 2 is complete when every tool check succeeds from a new terminal.**

## 3. Install dependencies and start local services

Run these commands in order:

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

They perform distinct jobs:

1. `bun install` installs every workspace dependency.
2. `services:start` starts PostgreSQL and resolves Function Runtime for `tools/devkit/external-services.docker-compose.yml`, then waits for their health checks. When Function Runtime inputs match a published commit, devkit pulls `ghcr.io/agentbull/ankole-function-runtime:<revision>` directly; when TypeScript inputs change while the native stage matches a published commit, Docker reuses that image's `/usr/local/bin/edge-runtime` binary and bundles the local TypeScript service; when the native stage or patches differ, Docker compiles the pinned Rust engine.
3. `services:status` shows the Compose service state.
4. `control-plane:setup` fetches Elixir dependencies, creates the development database, runs Ecto migrations, and loads seeds.

The first Elixir compile is much slower than a normal TypeScript install. Continued compile output is progress; do not interrupt it only because it takes several minutes.

If a command fails, preserve its first actionable error. Do not jump to a database reset, edit generated files, or bypass the root command with an improvised lower-level command.

**Stage 3 is complete when both services are healthy and `control-plane:setup` exits successfully.**

## 4. Start the complete development environment

Run:

```bash
bun dev
```

Keep this terminal open. The devkit starts or verifies PostgreSQL and Function Runtime, creates and migrates the local database, resolves a published or local Worker image, and starts Phoenix and the frontend assets with the Docker Worker provider. Agent creation requests a Worker container, which runs the local Agent Computer source in watch mode.

The devkit formats Phoenix logs and keeps service builds attached to the terminal.

When local runtime inputs diverge from published images, the first run may spend substantial time building the Function Runtime or Agent Computer images. Wait while there is active build output.

For the SaaS edition with its private source checkout, use the same command
with the edition selected:

```bash
ANKOLE_EDITION=saas bun dev
```

The SaaS root is `http://ankole.localhost:4000`, sign-in is on
`http://accounts.ankole.localhost:4000`, and site administration is on
`http://console.ankole.localhost:4000/site-admin-console`. Both editions use the
standard Worker image. The devkit reads `.env.dev`, `.env.dev.local`, and
`.env.local` from `app/control_plane`, in that order; OS variables take
precedence.

In another terminal, verify the visible boundaries:

```bash
bun run services:status
curl -I http://ankole.localhost:4000/
```

The database must be healthy and the HTTP request must reach the control plane. Then open [`http://ankole.localhost:4000`](http://ankole.localhost:4000). Create an Agent and wait for its Worker to become ready. List the containers with `docker ps -a --filter label=ankole.installation=dev`. Initial image preparation can take time; the creation request does not wait for it. After idle release, an environment tool or Job requests the Worker again; pure questions do not wait for it.

The development control plane listens on every interface, because Worker containers reach it through the Docker bridge gateway (`host.docker.internal`). On a shared network, block port 4000 from other machines.

Do not start a second `bun dev`. Stop the control plane with `Ctrl+C` in the original terminal; the devkit then removes the Worker containers of the `dev` installation.

PostgreSQL and Function Runtime run until you stop the support services:

```bash
bun run services:stop
```

**Stage 4 is complete when the local site opens.**

## 5. Complete first-time product setup

This section includes the exact Feishu permissions, events, callbacks, and field values needed by the current local path. Follow the order because later screens depend on resources created earlier.

Local Email OTP and invitations use the in-memory Swoosh mailbox. Read delivered
messages at `/dev/mailbox` on the current site or tenant host. Restarting the
control plane clears these messages. Deployed sites use their configured SMTP
transport.

### Activate the installation

On the first visit, the site opens the setup flow:

1. Click the page's reprint button.
2. Find `SETUP ACTIVATION CODE: ABCDEFGH` in the `bun dev` terminal.
3. Enter the eight-character code in the page.
4. Keep the Feishu/Lark adapter enabled in the plugin step.

If the code is not printed, query the active bootstrap value from a second terminal:

```bash
bun run kit show bootstrap-activation-code
```

If the Feishu identity-provider option is absent after enabling the plugin, stop and restart `bun dev` once, then return to setup.

### Create the Feishu test application

The human must create an enterprise custom app in the [Feishu Open Platform](https://open.feishu.cn/), enable its bot capability, and include the test user in the app's availability scope.

Use a name such as `Ankole Local` so the test application is not confused with a production application. Add the bot to the test group before the final smoke test.

#### Configure redirect URLs

Add these two URLs to the application's security settings:

```text
https://open.feishu.cn/app/<APP_ID>/safe
http://ankole.localhost:4000/sessions/oidc/lark-main/callback
```

Replace `<APP_ID>` in the first URL with this application's real App ID. Do not paste the placeholder literally.

The second URL is the OIDC callback sent by the current setup flow. Feishu requires an exact match between the request's `redirect_uri` and the allowlist.

Keep these identities consistent:

- identity provider ID: `lark-main`;
- OIDC callback: `http://ankole.localhost:4000/sessions/oidc/lark-main/callback`;
- Signal platform-principal namespace: `lark-main`.

`localhost` and `127.0.0.1` are different OAuth redirect URIs. Use the documented `localhost` URL unless you also update the exact Feishu allowlist entry.

#### Grant login and directory permissions

Use Feishu's bulk-import action to add this baseline:

```json
{
  "scopes": {
    "tenant": [
      "auth:user_access_token:read",
      "contact:contact.base:readonly",
      "contact:department.base:readonly",
      "contact:department.organize:readonly",
      "contact:user.base:readonly",
      "contact:user.department:readonly",
      "contact:user.email:readonly",
      "contact:user.employee:readonly",
      "contact:user.employee_id:readonly",
      "contact:user.phone:readonly"
    ],
    "user": [
      "component:user_profile",
      "offline_access"
    ]
  }
}
```

Those scopes cover login and directory sync. Import this second baseline for bot messages, reactions, resources, and CardKit:

```json
{
  "scopes": {
    "tenant": [
      "application:bot.basic_info:read",
      "cardkit:card:read",
      "cardkit:card:write",
      "im:chat:read",
      "im:chat.members:bot_access",
      "im:message.group_at_msg:readonly",
      "im:message.p2p_msg:readonly",
      "im:message.reactions:read",
      "im:message.reactions:write_only",
      "im:message:readonly",
      "im:message:send_as_bot",
      "im:message:update",
      "im:resource"
    ],
    "user": []
  }
}
```

If the Signal binding will use `observe_all` or `may_intervene`, also grant `im:message.group_msg`. The `addressed_only` smoke test does not need access to every group message.

Grant any related scope that Feishu requests while adding the events below.

Create and publish an initial app version that contains the bot capability, redirect URLs, permissions, and test-user availability. Unpublished settings do not apply to the test user.

#### Save the identity provider and complete OIDC login

Return to the Ankole setup flow and create the Feishu identity provider with these values:

| Field | Local value |
| --- | --- |
| Provider ID | `lark-main` |
| Domain | Feishu |
| App ID | The test application's App ID |
| App Secret | The test application's App Secret |
| OIDC | Enabled |
| Directory sync | Enabled |
| WebSocket incremental sync | Enabled |

Enter the App Secret in the browser. The coding agent should never request, read, repeat, or store it.

Choose the action that saves the provider and signs in with OIDC. After the human completes Feishu authorization, the first successful user becomes this installation's root administrator and the activation code expires.

Saving the provider also starts an outbound WebSocket connection from the local control plane. This needs internet access, but it does not need a public IP, reverse proxy, or tunnel.

Feishu may reject long-connection events before it detects the client. If that happens, finish saving the provider, keep `bun dev` running, and retry the event configuration.

#### Configure long-connection events and callbacks

Keep `bun dev` running. In Feishu's Events and Callbacks page, choose the long-connection option and add:

| Event | Identifier |
| --- | --- |
| Employee created | `contact.user.created_v3` |
| Employee deleted | `contact.user.deleted_v3` |
| Employee updated | `contact.user.updated_v3` |
| Department created | `contact.department.created_v3` |
| Department deleted | `contact.department.deleted_v3` |
| Department updated | `contact.department.updated_v3` |
| Message received | `im.message.receive_v1` |
| Message recalled | `im.message.recalled_v1` |
| Reaction created | `im.message.reaction.created_v1` |
| Reaction deleted | `im.message.reaction.deleted_v1` |
| Bot added to chat | `im.chat.member.bot.added_v1` |
| Bot removed from chat | `im.chat.member.bot.deleted_v1` |

Add the `card.action.trigger` callback. Without it, choices made on clarification cards cannot return to Ankole.

Publish another app version containing the event and callback changes. Confirm that the bot is enabled, the test user remains in scope, and the test group contains the bot.

Return to the Web Console. If the browser session expired, sign in again through the same `lark-main` identity provider.

### Configure the runtime in the Console

Create runtime resources in this order because each later resource references an earlier one:

1. **Provider.** Open Providers, choose the service you actually use, and enter a stable Provider ID, API key, endpoint if required, and model information. Save it and confirm it is available.
2. **Agent.** Open Agents and set its handle, display name, role, and Worker provider. Ankole generates its opaque UID. Configure `primary`, `light`, and `heavy` model profiles. One provider and model can temporarily serve all three.
3. **Signal binding.** Open Signals, select the agent and Feishu/Lark adapter, use `lark-main` as the binding name and principal namespace, enter the same app credentials and Feishu domain, then save and enable it.
4. **Worker.** Open Workers and confirm that the Agent has the selected Worker provider and no error. Its initial state is Absent. Environment tools or Codex start the Worker when required; pure questions and control-plane tools do not.

For a first group-chat smoke test, use `addressed_only`. It responds only when the bot is explicitly mentioned and needs fewer Feishu permissions than the full-message modes.

The identity provider and Signal binding are separate boundaries. Entering the same App ID and App Secret twice is expected; it does not require two Feishu apps.

If you need the financial MCP, add `BULLX_FINANCIAL_DATA_MCP_API_KEY` through the Console's encrypted worker-environment surface. Test it in a new agent turn after saving.

**Stage 5 is complete when the administrator can sign in, the provider and agent are usable, and the Signal binding is enabled.**

## 6. Prove the end-to-end path

Before sending a message, confirm:

- the Feishu app's latest version is published;
- the test user is in the availability scope;
- the bot is present in the test chat;
- the provider is usable and the agent has all three model profiles;
- the Signal binding is enabled;
- the Workers page shows no reason for the Agent's Worker.

Send `Please reply with LOCAL_OK only` in a direct chat with the bot. In a group using `addressed_only`, mention the bot and send the same request.

The reply must travel through the real path:

```text
Feishu event -> long connection -> Signal binding -> conversation driver -> AIGateway -> LLM provider
              <- CardKit/message <- Signal binding <- Outbox <- conversation driver
```

The setup passes only when Feishu shows `LOCAL_OK` from the configured agent and the `bun dev` terminal has no provider, permission, event, or worker error for that turn.

For a new Agent, confirm that this pure question leaves the Worker Absent.
Then ask the Agent to use `command` to print `LOCAL_TOOL_OK`. Confirm that its
computer starts and the tool result reaches the reply. This checks the Worker
path as well as the control-plane model path.

Seeing the page, database, or worker alone is not an end-to-end result. If this message does not complete, report the first boundary that failed.

**Stage 6 is complete when the real Feishu message returns `LOCAL_OK` through the configured agent. At that point, the full local environment is running end to end.**

## Troubleshoot from the first broken boundary

Start with the first error in the `bun dev` terminal. Later errors are often consequences of an earlier compile, database, port, or worker failure.

### Base shard databases

Development and test use four independent Base shard databases on the configured
PostgreSQL host. Startup creates missing databases from `template0` with the
control-plane locale. `MIX_TEST_PARTITION` also partitions their names. PostgreSQL
18 is required. Set `BASE_DB_URLS` to use explicit shard URLs; see
[Base storage placement](docs/design-docs/Tenants.md#base-storage-placement)
for URL parameters, production defaults, and backup requirements.

### Docker or PostgreSQL does not start

```bash
docker info
bun run services:status
docker ps --filter name=ankole
```

Start Docker Desktop or fix Linux Docker permissions before changing project code. Do not delete a Docker volume because one startup failed.

### The local database is genuinely disposable and damaged

The rebuild command deletes the local `ankole_dev` database. Run it only after the human confirms that the data can be lost:

```bash
bun run kit app-db rebuild --yes
bun run control-plane:setup
```

A failed migration or an unfamiliar Ecto error is not automatic permission to rebuild the database.

### The page does not open

```bash
curl -I http://ankole.localhost:4000/
lsof -nP -iTCP:4000 -sTCP:LISTEN
lsof -nP -iTCP:3035 -sTCP:LISTEN
```

Resolve the first process conflict or compile failure. Do not change the documented ports without also updating every dependent callback and worker endpoint.

### The activation code is missing

Click reprint, inspect the `bun dev` terminal, then use `bun run kit show bootstrap-activation-code`. Do not guess the code from browser internals or database rows.

### Feishu reports a redirect mismatch

Confirm that the browser origin, provider ID, and Feishu allowlist produce exactly:

```text
http://ankole.localhost:4000/sessions/oidc/lark-main/callback
```

### Login works but the bot does not reply

Check these boundaries in order:

1. The latest Feishu app version is published and the bot capability is enabled.
2. The test user and chat are in scope, and the bot is in the chat.
3. Message, CardKit, event, and callback permissions are active.
4. The Signal binding is enabled and points to the intended agent.
5. The agent has usable model profiles and the provider credentials are valid.
6. The Agent's Worker is Ready; otherwise the Workers page shows the backend's reason.

Inspect recent Worker output without dumping its environment:

```bash
docker ps -a --filter label=ankole.installation=dev --format '{{.Names}} {{.Label "ankole.agent-uid"}}'
docker logs --tail 200 CONTAINER_NAME
```

If the primary model profile is unavailable, inspect the Console's Agents and Providers pages before blaming Feishu ingress.

### A newly saved worker secret is unavailable

Worker environment changes are injected into new turns. Send a new message after saving the value; do not use an already-running turn to judge the change.

## Work on a contribution

Read [`AGENTS.md`](AGENTS.md) for scope, authorization, ownership, and implementation rules.

### Repository map

| Path | Responsibility |
| --- | --- |
| `app/control_plane` | Phoenix/OTP control plane application: domain and web modules, OTP entry points, release and upgrade modules, Mix tasks, configuration, migrations, and the test suites |
| `app/agent_computer` | Bun/TypeScript Worker, environment tools, Codex, Skills, files, and terminal state |
| `app/kernel` | Rust library loaded through Rustler and browser Node-API bindings |
| `app/function_runtime` | Stateless Applet backend and deterministic program workers |
| `app/webapps` | Vite/React setup, authentication, Pod, and Console applications |
| `app/library` | Built-in agent skills and starter templates |
| `app/locales` | Shared translation catalogs |
| `libs/` | Shared UI, editor, transport, and protocol libraries |
| `plugins/` | Trusted first-party Plugin source and provider clients compiled by the control plane |
| `tools/devkit` | Repository automation, local services, database helpers, and analysis |
| `tools/e2e` | Dedicated integration and end-to-end suites |
| `docs/design-docs` | Current design intent for non-trivial subsystems |

### Repository toolkit

The devkit keeps repository chores on the supported paths:

```bash
bun run kit --help
bun run services:status
bun run workspace:update
bun run analyze
```

Use `kit --help` to discover database, service, generation, worker-test, and analysis commands instead of guessing lower-level invocations.

## Run the right checks

Start with the targeted checks that cover the area you changed—failures are much faster to diagnose when isolated from unrelated worktree activity.

On pull requests and pushes to `main`, the `Repository checks` GitHub Actions workflow runs three static-verification jobs against the FOSS edition:
- **`bun-static`** — `oxlint`, `oxfmt`, workspace dependency/unused-export analysis, and TypeScript checks
- **`kernel-lint`** — `rustfmt`, `clippy` across every Cargo feature combination, and Elixir formatting
- **`control-plane-lint`** — Elixir formatting, `mix compile --warnings-as-errors`, Credo, compile-connected cycle checks, Plugin dependency boundaries, and OpenAPI / generated SDK drift checks

Once those static checks pass on `main`, the runtime-image workflow builds, verifies, and publishes release images for that commit.

| Changed area | Recommended initial checks |
| --- | --- |
| Documentation only | `git diff --check` plus link and command verification |
| Repository tooling or shared TypeScript | `bun run lint:repo` and `bun run fmt:check:repo` |
| Control Plane | `bun run --filter @ankole/control-plane type-check` and `bun run control-plane:test` |
| Agent Computer | `bun run agent-computer:type-check` and `bun run agent-computer:test` |
| Webapps | `bun run webapps:type-check`, `bun run --filter @ankole/webapps test`, and `bun run webapps:build` |
| Kernel | `bun run --filter @ankole/kernel lint` and `bun run --filter @ankole/kernel test` |
| Function Runtime | `bun run --filter @ankole/function-runtime type-check`, `bun run --filter @ankole/function-runtime test`, `bun run --filter @ankole/function-runtime test:integration` (with local services running), and `bun run --filter @ankole/function-runtime test:native` (against the built image) |
| Browser | `bun run --filter @ankole/browser lint`, `bun run --filter @ankole/browser test`, and `bun run --filter @ankole/browser test:integration` (with `ANKOLE_BROWSER_TEST_CHROMIUM` pointing to Chromium) |
| Provider clients | `bun run control-plane:test:plugins` (or `bun run lark-adapter:test` for Feishu/Lark alone) |
| Block editor | `bun run --filter @ankole/block-editor type-check`, `bun run --filter @ankole/block-editor test`, and `bun run --filter @ankole/block-editor test:package` |
| Website | `bun run --filter @ankole/website type-check` and `bun run --filter @ankole/website build` |

### Subsystem check notes

- **Function Runtime (`test:integration` & `test:native`)**: Protocol integration tests spin up a local HTTP webhook receiver that the devkit container reaches via `host.docker.internal`. `test:native` launches an ephemeral container from `ankole-function-runtime:dev` (override with `ANKOLE_FUNCTION_RUNTIME_TEST_IMAGE`) to verify CPU-limit shutdown events, physical PTC cancellation, one-shot and warm-worker thread retirement, resident memory at 20 and 100 workers, and `SIGTERM` draining (using shortened wall-clock limits rather than production's 5-minute Applet ceiling), then prints the artifact directory containing native event logs and resource metrics before removing the container.
- **Website TypeScript version pin**: `app/website` intentionally pins TypeScript `6.0.3` while the rest of the workspace uses TypeScript 7, because `@astrojs/check` supports only TypeScript 5–6 (`astro check` errors on 7.0, and `@astrojs/ts-content-mapper` requires 7.1+). Keep that pin until Astro supports TypeScript 7.1+.
- **Control-plane test partitioning and incremental runs**: `bun run control-plane:test` compiles `:ankole` once and executes the suite across isolated `MIX_TEST_PARTITION` worker processes (`ANKOLE_TEST_PARTITIONS` overrides the worker count). For incremental feedback on changed modules, run `bun run control-plane:test:stale`; to run one ExUnit file directly, pass its path (`bun run control-plane:test test/path/to/file_test.exs`) or `cd app/control_plane && mix test test/path/to/file_test.exs`.
- **Loopback TCP disconnect tests**: Protocol tests that verify upstream TCP disconnects need direct loopback sockets rather than going through an HTTP proxy (which holds its own separate connection). Ensure `NO_PROXY` includes `127.0.0.1`, `localhost`, and `::1` alongside any existing exclusions.
- **Database-free plugin unit tests**: From the repo root, run all or one plugin's unit suite without PostgreSQL:
  ```bash
  bun run control-plane:test:plugins
  bun run control-plane:test:plugins lark_adapter
  ```
  Under the hood, `mix ankole.plugins.test` compiles `:ankole` in `:test`, skips full application boot, and runs each plugin's `test_helper.exs` to start only its own supervisor (the full `control-plane:test` suite runs these tests as well).
- **Credo and unused-code gates**: Control-plane lint enforces Credo's default suite, `ex_slop`, and Ankole's custom checks with zero baseline exemptions (max nesting depth `4`, max cyclomatic complexity `20`). If a PR eliminates all remaining findings for a check currently marked `disabled` in `app/control_plane/.credo.exs`, re-enable that check in the same PR. Likewise, `bun run analyze:unused` flags dead production files, exports, types, and dependencies—test-only callers do not keep unused production code alive.
- **Pinned Elixir dependency patches**: Before compiling Mix dependencies, `app/control_plane` applies local patches to Ash `3.37.2`, AshPostgres `2.15.1`, AshJsonApi `1.8.0`, and `attesto` `2.6.1` (requiring `patch` on `PATH`, preinstalled in Docker). Each `_build` tree tracks a content stamp over the patches and patch loader; whenever either changes, Mix recompiles the patched packages and clears `:ankole`'s build cache, failing hard if any hunk fails to apply. Together these patches silence spurious notification warnings, handle tenant-invisible skipped upserts, emit accurate native OpenAPI schemas (timestamps, embedded IDs, nullable array items, `DELETE` responses), honor halted `before_dispatch` plugs in JSON:API routers, accept Ankole's opaque Principal UIDs in `attesto`, and treat Ash/AshJsonApi resource-reference DSL entries as runtime rather than compile-time module edges (while keeping verifier coverage intact). Re-verify public action behavior whenever bumping these libraries, and drop each patch once upstream ships the fix.
- **Compile-connected cycle and boundary checks**: Whenever you change module references in `app/control_plane`, verify both `:test` and `:prod` graphs (since `:prod` initializes plugs at compile time):
  ```bash
  MIX_ENV=test ANKOLE_EDITION=foss mix ankole.compile_cycles
  MIX_ENV=prod ANKOLE_EDITION=foss mix ankole.compile_cycles
  ```
  `mix ankole.compile_cycles` rejects any cycle containing at least one compile-time edge across `:ankole` and its local Mix dependencies (pure runtime cycles are fine), and enforces directory boundaries: core domain code (`app/control_plane/lib` and `internals/control_plane/lib`) must never statically reference a concrete Plugin, nor may one Plugin statically reference another (the sole legacy upgrade exceptions are `Ankole.Upgrade202610` referencing `Ankole.Plugins.SlackAdapter.Config` and `Ankole.Plugins.Microsoft365Adapter.Config`; see [Control Plane Plugins](docs/design-docs/Plugins.md#fixed-source-builds)). Endpoints and Routers wrap business plugs in local function plugs, and the SaaS router uses `AnkoleWeb.runtime_forward` so forwarded targets stay runtime-only edges. Also run both commands with `ANKOLE_EDITION=saas` when `internals/` is present, and never pass `--only-direct` (which hides transitive compile cycles). To run the standalone xref boundary suite without PostgreSQL:
  ```bash
  elixir -e 'ExUnit.start(); Code.require_file("integration/compile_cycles_test.exs")'
  ```
- **Session Driver & integration suites**: Run Session Driver cluster/transaction tests in an isolated partition with a short node name:
  ```bash
  cd app/control_plane
  MIX_TEST_PARTITION=session_driver elixir --sname session_checks@localhost -S mix test integration/session_driver_test.exs
  ```
  Running `bun run test:integration` inside `app/control_plane` executes PostgreSQL + Function Runtime integration suites while excluding `cloud`, `cluster`, and `external` tags (covered below).
- **Agent Computer test tiers**: `bun run agent-computer:test` runs host unit tests (requires Bun, Bash, GNU `timeout`, Python 3). Inside `app/agent_computer`, `bun run test:integration` runs portable host integration tests with Codex `0.164.0`, MCPorter `0.16.0` on Bun, native `apply_patch`, and GNU `stat` (`gstat` on macOS), honoring `ANKOLE_CODEX_BINARY` and setting `TMPDIR=/tmp` to keep Unix socket paths short. On Linux, also run `bun run test:integration:linux` (`setsid` + util-linux `flock -F`). Docker-backed checks (`bun run test:integration:docker` and `bun run test:docker`) verify the packaged Worker image (`tini`, pinned Codex bindings, browser, OCR, Lark CLI).

### Persistence boundary

Control-plane persistence is owned by **Ash resources**, with each domain's root module (such as `Ankole.Signals`) acting as its `Ash.Domain`. External callers—other domains, `ankole_web`, plugins, and OTP startup code—interact with a domain strictly through its root `define` interfaces and public functions:

- **Composable resource actions**: Resource `create`, `update`, and `destroy` actions never open their own database transaction; each runs either as a single SQL statement or inside the caller's active transaction.
- **Top-level multi-step writes**: Multi-step intra-domain writes use `Ankole.Repo.transact_top_level/2`, which owns the outer transaction and raises `Ankole.Errors.Framework.NestedOperation` if called inside an existing `Repo.transact` or transactional generic action. Schedule post-commit side effects via `after_commit: fun` or run them after `transact_top_level/2` returns.
- **JSON:API generic actions**: Commands or non-resource JSON:API endpoints declare generic actions on either the subject resource or a stateless `Ash.DataLayer.Simple` resource. Resource generic actions open a transaction automatically unless they set `transaction?(false)` and delegate to a domain function that calls `Repo.transact_top_level/2`. Stateless `Ash.DataLayer.Simple` transport actions always set `transaction?(false)` and delegate transaction ownership and commit notifications to the underlying domain functions after `Principal`/`AuthZ` authorizes the route.
- **Cross-domain transactional steps (`*_in_tx`)**: When Domain A needs to invoke Domain B inside A's open transaction, Domain B exposes a `*_in_tx(...)` function that uses `Ankole.Repo` implicitly, raises `Ankole.Errors.Framework.TransactionRequired` if called outside a transaction, and never opens a nested transaction, publishes events, or wakes processes on its own. Cross-domain row locks go exclusively through the owning domain's `lock_*_in_tx` helper.
- **Executing Ash operations (`Ankole.Ash`)**: Inside its own directory, a domain executes queries and changesets through `Ash.Query` and `Ankole.Ash` (`read/2`, `read_one/2` with `lock_identity:` for row locks, `read_across_tenants!/2` for `allow_global` reads, `create/4`, `update/4`, `destroy/3`, `update_atomic/4`, `update_where/4`, `destroy_where/4`, `insert_if_absent/4`, and `run_action/4`), which bind the active `Ankole.Repo` process tenant automatically.
- **Avoiding resource-to-domain compile cycles**: Because an `Ash.Domain` compiles its code interface from its resources, a resource module must never call code that transitively references an `Ash.Domain` (which would create a compile-connected cycle caught by `mix ankole.compile_cycles`). Instead, reference domain-calling hooks by module name in the resource DSL (with `infer_generic_action_reactors?: false` configured on `:ash`, Spark records DSL module names without adding compile-time edges; if your local build cache used a different setting, run `mix deps.compile ash --force`), placing those companion modules under the resource's subdirectory:
  - `run(__MODULE__.Actions)` — `<Resource>.Actions` (`use Ash.Resource.Actions.Implementation`) dispatches JSON:API generic actions by clause (e.g., `Ankole.Tenants.Tenant.Actions` in `tenants/tenant/actions.ex`).
  - `prepare(__MODULE__.Preparations)` — `<Resource>.Preparations` houses query/changeset preparations that call domain code.
  - Calculations, validations, or changes that call domain code each live in their own focused module (e.g., `Ankole.Brain.Schemas.MergeSuggestion.PageSummary`).
  - Procedural helpers that both touch a resource and call other domain modules live in a separate sibling module (e.g., `Ankole.Conversations.Delivery.PreviewStates` alongside `PreviewState`).
  - Inline anonymous functions in the DSL and functions defined directly on the resource module may call only leaf utilities that never touch a domain (such as `Ankole.Errors`, `Ankole.Repo`, or `Ankole.Files.Path`).
- **Domain error wrapping (`Ankole.Errors`)**: Resource actions surface `Invalid.Stale`, `Invalid.StatusTransition`, or `Invalid.NotFound`, while generic actions wrap domain rejection reasons into `Invalid.Rejected` via `Ankole.Errors.wrap/1`. Callers extract reasons with `Ankole.Errors.reason/1` rather than pattern-matching raw `Ash.Error` structs, and `AnkoleWeb.ConsoleErrors.fallback/4` translates those errors into HTTP responses.

For the handful of low-level subsystems whose access patterns do not fit Ash resource semantics—process coordination (`M2`), flat read models (`M4`, returning maps/scalars rather than resource structs), dynamic Base schemas (`M7`), set maintenance (`M8`), or hybrid search retrieval (`M9`)—`app/control_plane/test/ankole/persistence_boundary.exs` maintains an explicit, user-approved allowlist. Only allowlisted modules may run direct Ecto writes, Ecto row locks, `Repo.transact`, or raw Ecto queries over resource tables, and stale allowlist entries fail the test once migrated to Ash.

Four automated checks enforce this boundary continuously:
- **`Ankole.Ash.Verifiers.Contracts`** validates tenant and transaction rules at resource compile time.
- **`test/ankole/persistence_boundary_test.exs`** inspects compiled modules to catch unauthorized Ecto queries on resource tables or cross-domain Ash resource calls.
- **Credo `AshBoundary`** rejects unauthorized Ecto writes/locks, `Repo.transact`, direct `Ash.*` / `Ash.bulk_*` calls, transaction hooks, manual bulk-result decoding, `Ash.Error` pattern matches, Ash calls from `ankole_web`/plugins/`Application`, and update/destroy filters that omit `change(filter(...))`.
- **Credo `RawSQLTenant` & `test/ankole/tenancy_guard_test.exs`** require `tenant_id` filtering in raw SQL unless a module declares `@raw_sql_scope :site` (no tenant rows) or `@raw_sql_scope :tenant_schema` (physical Base modules using `BaseRepo` helpers keyed off `Repo.tenant_id!()`), and lock down the exact reviewed inventory of raw SQL, fragments, and cross-tenant reads per function.

### Pod content checks

Unit and integration tests for the Pod domain live under `test/ankole/pod/`, while dedicated integration suites exercise concurrent page moves, interrupted purges, tenant teardown, and 100,000-row physical Base queries against real committed PostgreSQL transactions (run these in a separate `MIX_TEST_PARTITION`). The GitHub sync integration test carries the `external` tag because it performs a read-only call against the public GitHub API; run it explicitly when internet access is available.

To run the real-browser Playwright suite against production Pod bundles, the Applet SDK, and the site Console (using three Pod Human identities plus one site administrator), execute these three steps across separate terminals:

```bash
# 1. Build production frontend bundles
cd app/webapps
bun run build
```

```bash
# 2. Create the dedicated browser-test database and launch the fixture server
cd app/control_plane
MIX_ENV=test MIX_TEST_PARTITION=pod_browser mix ecto.create
MIX_ENV=test MIX_TEST_PARTITION=pod_browser mix ecto.migrate
MIX_ENV=test MIX_TEST_PARTITION=pod_browser \
  POD_BROWSER_STATE_PATH=/tmp/ankole-pod-browser.json \
  mix run --no-start integration/support/pod_browser_server.exs
```

```bash
# 3. Run the Playwright browser suite
cd app/webapps
POD_BROWSER_STATE_PATH=/tmp/ankole-pod-browser.json bun run test:pod
```

How `pod_browser_server.exs` works:
- **Host, port, and state file**: By default the server binds `127.0.0.1:4000` (stop any competing server on `:4000` first, or set `POD_BROWSER_PORT` alongside a distinct `pod_browser_*` `MIX_TEST_PARTITION`) and serves built production assets on `http://<tenant-slug>.ankole.localhost:4000`. Always navigate via the canonical `base_url` and shared account-proof cookies written to `POD_BROWSER_STATE_PATH` (`0600` permissions; delete it after testing) rather than hitting `127.0.0.1` directly or appending `?tenant_id=` query parameters.
- **Real connections and real auth**: The server uses the standard Ecto connection pool (not SQL Sandbox) so Phoenix Channels stay alive across requests, creates a fresh data tenant on each boot, reuses a fixed root-administrator Principal in the privileged tenant, and delivers login OTPs through a local TLS SMTP fixture whose `.mail.json` companion file lets Playwright read delivered codes without bypassing authentication or AuthZ.
- **Coverage**: The suite verifies live collaborative page edits, Base tables, Applet publishing, access revocation, Office file previews, Console member/guest provisioning and access-version bumps across reloads, iframe module loading, CSS isolation, per-tab identity selection, and the full sample-reservation Applet backend (pending submissions, input retention on rejection, viewer write denial, competing reservations, and paired frontend/backend revision swaps—delaying one real committed HTTP response solely to inspect pending UI state).

### Console API and OpenAPI

Ankole exposes JSON:API (`application/vnd.api+json` via `AshJsonApi`) on `/api/v2` for tenant-scoped Console operations and `/api/v2/site` for site administration. Both routers share the browser session and CSRF pipelines in `AnkoleWeb.Router`, while `/api/v2` additionally binds the active tenant context. Each Ash domain mounts in either `AnkoleWeb.JSONAPI.ConsoleRouter` or `AnkoleWeb.JSONAPI.SiteRouter` (never both), declaring routes in the domain's `json_api` block and resource types/default fields in each resource's `json_api` block.

Transport conventions across API surfaces:
- **Resource vs. generic actions**: Standard CRUD routes exchange JSON:API resource documents (`data.type`, optional `data.id`, `data.attributes`), whereas generic actions accept typed arguments directly under `data` (e.g., `{"data":{"value":true}}`). Routes configured with `wrap_in_result?: false` return their typed payload directly—check the generated TypeScript operation signature before consuming a response.
- **Non-JSON:API endpoints**: Agent Drive uploads/downloads use native multipart and binary responses under `/api/v2/agents`, Applet HTTP forwarding and SSE keep their native streaming semantics under `/api/v2`, OIDC and OpenAI-compatible endpoints keep their standard protocol paths, and initial setup, email OTP login, and browser session switching run through the dedicated Browser JSON:API router (which, like the Pod and SaaS routers, supplies its own request context without requiring a Console admin session).

Every Console and Site JSON:API route must satisfy three compile-time and test-enforced invariants (`router_test.exs` and `native_authorization_routes_test.exs`):
1. **Unique `name`**: Serves as the OpenAPI `operationId` and generated TypeScript SDK function name.
2. **Explicit `authz` rule**: Declared on the owning resource and evaluated by `Ankole.AuthZ.Authorizer` against the explicit Actor via `Principal`/`AuthZ` (verifiers require complete routed-action coverage, target resolvers, and `json_api.authorize?(true)`).
3. **Explicit list inputs**: Declared on read actions, with derived filters and sorts disabled (`index` and `related` routes must also pass `derive_sort?: false` explicitly because `AshJsonApi` `1.8.0` ignores the resource-level flag).

OpenAPI specs in `app/webapps/openapi/` (`browser-v2.json`, `pod-v2.json`, `console-v2.json`, `site-v2.json`, plus `internals/webapps/openapi/saas-v2.json` when `ANKOLE_EDITION=saas`) are exported directly from `AshJsonApi.Router.spec/0`. Whenever you change an exposed action, route, or field, regenerate both the specs and TypeScript clients (never hand-edit `api/generated`, `api/v2/generated`, or `api/v2-site/generated`):

```bash
cd app/control_plane
mix ankole.openapi.check --write
cd ../webapps
bun run openapi:generate
```

On the frontend, unwrap resource documents with `fromDocument` and consume typed generic-action results directly (bare resource returns serialize using the resource's `default_fields`). Both FOSS and SaaS CI pipelines fail if committed OpenAPI specs or generated SDKs drift from the Elixir declarations.

### Full local quality gate

Before opening or updating a pull request with cross-cutting code changes, run:

```bash
bun run lint
bun run type-check
bun run fmt:check
bun run analyze
bun run test
git diff --check
```

(`bun run fmt` formats files in place.) If an unrelated pre-existing failure exists elsewhere in the shared worktree, report your scoped check results separately alongside the exact ambient error—never weaken a test or bypass a production code path just to force an aggregate command green.

### End-to-end suites

`tools/e2e/run` builds any missing or stale Worker image automatically and starts PostgreSQL and Function Runtime when needed:

```bash
tools/e2e/run --help
tools/e2e/run
tools/e2e/run --perf
tools/e2e/run --chaos
tools/e2e/run --real-provider --providers=available
tools/e2e/run --real-llm
tools/e2e/run --all
```

Because these suites take longer than unit tests, run the specific mode that covers the boundary you changed (`--real-provider` and `--real-llm` require live operator test credentials):

- **Compose upgrade & authn gates**: The default `--gate` run includes `compose_upgrade`, which upgrades a live Docker Compose stack from the pooled release pinned in `tools/e2e/pooled-worker-revision` to the current control-plane build (pass `ANKOLE_E2E_CONTROL_PLANE_IMAGE` when running with `--no-build`, or isolate it via `tools/e2e/run --gate --only=compose_upgrade`). Similarly, `tools/e2e/run --gate --only=authn_compose` verifies fresh SMTP setup and password-to-OTP migration (preserving Human UIDs, encrypted mail settings, admin roles, and post-restart login). For faster database + TLS SMTP authentication stories without full Compose:
  ```bash
  cd app/control_plane
  MIX_TEST_PARTITION=authn mix test integration/authn_email_transport_test.exs \
    integration/authn_membership_stories_test.exs integration/authn_otp_concurrency_test.exs
  ```
- **Chaos & demand-window isolation**: Idle-release and image-replacement scenarios in `--chaos` commit real transactions and wait through the five-minute Worker demand window—never run another test suite against the same database partition concurrently.
- **Pod collaboration with real LLMs (`pod_content_real_llm`)**: Requires OpenRouter test credentials and built production frontend bundles (`app/webapps/ bun run build`), running four end-to-end browser stories (`pod_content_browser_report`, `pod_content_pure_spa`, `pod_content_research`, `pod_applet_backend`) over the standard SQL connection pool:
  ```bash
  tools/e2e/run --real-llm --only=pod_content_real_llm
  ```
  Across these four stories, a Human uses browser Chat to generate a report, typed Base sales table, formula, and Applet, submits a sale through the published Applet, requests an edit via Page Chat without re-stating the Page ID, revokes Agent access, and deletes the Conversation while verifying its Pages survive; a second story builds and exercises a pure frontend SPA and verifies that an Agent with space `edit` access (in Main or a Job) can move Pages while preserving subpage permissions; the research story invokes the built-in research Skill into a linked editable Page; and `pod_applet_backend` has an Agent build and update a sample-reservation Applet, verifying caller-attributed `POST` writes and retained rejected inputs (always asserting saved database state rather than trusting Job completion text alone).
- **Skill Lessons & Dreaming (`pod_skill_lessons_real_llm`)**: Grants a Human chat/tool access to an Agent with zero external Bindings, triggers two real Docker Worker Jobs that hit and repair a named-key `openpyxl` failure, invokes the Dreaming reflection phase on the Worker, and verifies that persisted lessons render into production Skills without leaking public chat replies or external deliveries (tests the reflection pipeline directly rather than the cron timer):
  ```bash
  tools/e2e/run --real-llm --only=pod_skill_lessons_real_llm
  ```
- **DeepSeek user stories & crash recovery**: Uses `deepseek/deepseek-v4.1-flash` via OpenRouter (`OPENROUTER_API_KEY` or `OPEN_ROUTER_API_KEY`) paired with `FakeFeishu` transport (spinning up Docker Workers only for computer-tool scenarios, while direct replies, Skill views, and clarifications stay in the control plane):
  ```bash
  tools/e2e/run --real-llm --only=deepseek_release_stories
  tools/e2e/run --real-llm --only=deepseek_clarification_flow
  ANKOLE_REAL_LLM_E2E=1 tools/e2e/run --chaos --only=real_llm_chaos
  tools/e2e/run --real-llm --only=deepseek_delivery_chaos
  ANKOLE_REAL_LLM_E2E=1 tools/e2e/run --gate --only=real_llm_compose_chaos
  ```
  The first four run the control plane in the test BEAM, while `real_llm_compose_chaos` runs both the control plane and PostgreSQL in containers (reusing the `compose_upgrade` image preflight), kills the control plane, restarts PostgreSQL, and verifies production reconciliation. Always assert stored file contents, side-effect counts, and platform-visible replies/attachments rather than trusting model prose: after a Worker crash, non-idempotent tools with an ambiguous outcome must return an interrupted error until inspected, whereas only declared retry-safe tools rerun automatically; in clarification flows, sending a normal WebSocket message supersedes an open card, while only managed card callbacks mark the interaction answered.
- **Two-node BEAM cluster suite**: Verifies single-writer exclusivity, epoch fencing, settings invalidation, cross-node routing, and graceful node-shutdown recovery across two named BEAM nodes against real PostgreSQL (using test fakes for the LLM and Worker channel):
  ```bash
  cd app/control_plane
  MIX_TEST_PARTITION=conversation_loop_cluster \
    elixir --sname ankole_session_checks@localhost -S mix test \
    integration/session_driver_test.exs --trace
  ```

### Worker provider checks

The Worker provider suites exercise production provider adapters directly—creating and deleting instances, remounting persistent Home storage across replacements, interrupting the coordinator mid-transition to verify row locks and recovery, and testing concurrent seed imports (`worker_provider_transactions_test.exs`). Always run them in dedicated `MIX_TEST_PARTITION` databases separate from fast unit tests (note that `kind` and `FakeFeishu` suites verify Kubernetes/Worker/storage mechanics rather than live LLM or live Feishu behavior).

#### Local Docker & Kubernetes (`kind`) suite

Requires `docker`, `helm`, `kubectl`, and `kind`. Always pass the temporary `--kubeconfig` (never point tests at a production cluster). Note that `kind` inherits `HTTP_PROXY` / `HTTPS_PROXY` from your shell—if you run a local proxy, bind it to an address reachable from inside the `kind` container (such as `http://host.docker.internal:<port>` on Docker Desktop) rather than `127.0.0.1`, or pulling the NFS fixture image will fail; Pods also reach the host control plane via `host.docker.internal`:

```bash
WORKER_PROVIDER_TEST_DIR=$(mktemp -d)
bun tools/devkit/src/local-worker-image.ts --scope complete --output "$WORKER_PROVIDER_TEST_DIR/image"
export ANKOLE_WORKER_PROVIDER_TEST_IMAGE=$(cat "$WORKER_PROVIDER_TEST_DIR/image")
export ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG="$WORKER_PROVIDER_TEST_DIR/kubeconfig"

kind create cluster --name ankole-worker-provider-test \
  --image kindest/node:v1.37.0 --kubeconfig "$ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG"
kind load docker-image "$ANKOLE_WORKER_PROVIDER_TEST_IMAGE" --name ankole-worker-provider-test
kubectl --kubeconfig "$ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG" apply \
  -f app/control_plane/integration/fixtures/kubernetes_worker_storage.yaml
kubectl --kubeconfig "$ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG" rollout status \
  deployment/nfs-provisioner --timeout=60s

cd app/control_plane
MIX_TEST_PARTITION=worker_provider mix test \
  integration/docker_worker_storage_test.exs \
  integration/compose_agent_home_migration_test.exs \
  integration/kubernetes_worker_storage_test.exs \
  integration/helm_worker_provider_seed_test.exs \
  integration/agent_worker_lifecycle_test.exs \
  integration/kubernetes_worker_lifecycle_test.exs \
  integration/kubernetes_worker_user_flow_test.exs \
  integration/worker_provider_transactions_test.exs
cd ../..

kind delete cluster --name ankole-worker-provider-test \
  --kubeconfig "$ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG"
rm -r "$WORKER_PROVIDER_TEST_DIR"
```

This `kind` fixture tests both exclusive `local-path` PVCs (`standard`) and shared RWX NFS PVCs (`example-nfs`, pinned to NFS-Ganesha `4.0.8` over NFSv4.0; CSI block volumes and node-loss failover are out of scope), plus the internal Helm chart when `internals/` is present. To validate real **AWS EFS** storage against an approved test directory, spin up a separate `kind` cluster, replace the Ganesha deployment with a static RWX NFS PV (`storageClassName: example-nfs` backed by `kubernetes.io/no-provisioner`, capacity `128Mi`, `persistentVolumeReclaimPolicy: Retain`, `mountOptions: ["vers=4.1", "hard"]`; if tunneling over TCP, set `port` only—never `mountport`, since EFS has no NFSv3 mountd), run `kubernetes_worker_storage_test.exs` unchanged, and tear down all test resources afterward. Note that shared-PVC `.deleted/` rename-and-purge cleanup must be verified on real NFSv4.1 / EFS targets, as neither the `kind` NFSv4.0 fixture nor local bootstrap tests prove production EFS behavior.

#### Local Linux bootstrap checks (AWS Lambda & Alibaba Cloud FC)

Without calling AWS or Alibaba Cloud APIs, you can verify container entrypoint invariants locally on Linux:

- **Lambda NFSv4.1 bootstrap** (requires privileged Linux containers and kernel `nfsd`; verifies root bootstrap, `uid 1000` access, directory isolation, container replacement, and idempotent deletion hooks):
  ```bash
  bun tools/devkit/src/local-worker-image.ts --scope complete --output /tmp/ankole-worker-image
  export ANKOLE_WORKER_PROVIDER_TEST_IMAGE=$(cat /tmp/ankole-worker-image)
  docker build --build-arg WORKER_IMAGE="$ANKOLE_WORKER_PROVIDER_TEST_IMAGE" \
    -f app/control_plane/integration/fixtures/nfs-server.Dockerfile \
    -t ankole-worker-nfs-test .
  cd app/control_plane
  ANKOLE_NFS_TEST_SERVER_IMAGE=ankole-worker-nfs-test \
    MIX_TEST_PARTITION=worker_provider mix test integration/lambda_worker_bootstrap_test.exs --trace
  ```
- **Function Compute contract bootstrap** (verifies admission gating, root identity, `sudo` removal, preserved writable Home ownership, fail-fast on read-only Home, and idempotent Worker/deletion contracts):
  ```bash
  cd app/control_plane
  ANKOLE_WORKER_PROVIDER_TEST_IMAGE=$(cat /tmp/ankole-worker-image) \
    MIX_TEST_PARTITION=worker_provider mix test integration/function_compute_worker_bootstrap_test.exs --trace
  ```

#### Approved live cloud provider suites (Cloudflare, Vercel, AWS Lambda, Alibaba Cloud FC)

All four live cloud suites drive the real coordinator, `RuntimeFabric` Channel, and HTTP file relay against two distinct Worker images and a publicly reachable HTTPS/WebSocket test control plane (`*_CP_ORIGIN`, no trailing slash, forwarded to local `*_CP_PORT`). Always obtain explicit approval before provisioning cloud resources, store temporary credentials outside the repository, use a dedicated test database per suite, and **keep that test database until every cloud instance and storage bucket/volume is confirmed deleted** (if cloud teardown fails, unresolved Worker rows stay in PostgreSQL so you can clean them up):

- **Cloudflare Containers + R2** (requires a dedicated adapter, R2 bucket, and two digest-pinned `amd64` images; set `ANKOLE_CLOUDFLARE_TEST_ADAPTER_URL`, `ANKOLE_CLOUDFLARE_TEST_ADAPTER_TOKEN`, `ANKOLE_CLOUDFLARE_TEST_IMAGE`, `ANKOLE_CLOUDFLARE_TEST_REPLACEMENT_IMAGE`, `ANKOLE_CLOUDFLARE_TEST_CP_PORT`, `ANKOLE_CLOUDFLARE_TEST_CP_ORIGIN`; does not test forced platform kills, Durable Object restarts, or raw R2 object inspection):
  ```bash
  cd app/control_plane
  MIX_TEST_PARTITION=cloudflare_worker_provider mix test \
    integration/cloudflare_worker_storage_test.exs --trace
  ```
- **Vercel Sandbox + Drive** (first persist `"vercel-worker-provider"` in `plugins.enabled_ids` in the test partition and restart the test VM, keeping it enabled through cleanup; set `ANKOLE_VERCEL_TEST_TOKEN_FILE`, `ANKOLE_VERCEL_TEST_TEAM_ID`, `ANKOLE_VERCEL_TEST_PROJECT_ID`, `ANKOLE_VERCEL_TEST_REGION`, `ANKOLE_VERCEL_TEST_IMAGE_REPOSITORY`, ready VCR digests in `ANKOLE_VERCEL_TEST_IMAGE` and `ANKOLE_VERCEL_TEST_REPLACEMENT_IMAGE`, `ANKOLE_VERCEL_TEST_CP_PORT`, and `ANKOLE_VERCEL_TEST_CP_ORIGIN`; pass `ANKOLE_VERCEL_TEST_SESSION_TIMEOUT_SECONDS=2700` on accounts capped at 45-minute sessions instead of the 24-hour default):
  ```bash
  MIX_TEST_PARTITION=vercel_worker_provider mix test integration/vercel_worker_storage_test.exs --trace
  ```
- **AWS Lambda + EFS** (prepare S3 build bucket, IAM build role, EFS root, VPC connector, and NAT; check `GetServiceQuota` for applied ARM64 memory first—the two-Agent flow needs room for two simultaneous instances, i.e., at least `8 GiB` free at the default `4096 MiB` size, with `4096` and `8192 MiB` supported, and wait for AWS to report `TERMINATED` on deletion helpers before reusing capacity; set `ANKOLE_LAMBDA_TEST_CONFIG_FILE`, `ANKOLE_LAMBDA_TEST_CREDENTIALS_FILE` with temporary `accessKeyId`/`secretAccessKey`/`sessionToken`, `ANKOLE_LAMBDA_TEST_IMAGE`, `ANKOLE_LAMBDA_TEST_REPLACEMENT_IMAGE`, `ANKOLE_LAMBDA_TEST_CP_PORT`, `ANKOLE_LAMBDA_TEST_CP_ORIGIN`):
  ```bash
  MIX_TEST_PARTITION=lambda_worker_provider mix test integration/lambda_worker_storage_test.exs --trace
  ```
- **Alibaba Cloud Function Compute (AgenticFS & OSS)** (first enable `"china-market-ai-providers"` in `plugins.enabled_ids` and restart; requires an account with Gen-2 memory pause enabled and both images pushed to ACR Enterprise; run **twice**—once with AgenticFS and once with OSS, where the OSS run pauses 90s to force stale TCP drops and asserts retained-file read recovery within 30s—setting `ANKOLE_FUNCTION_COMPUTE_TEST_CONFIG_FILE`, `ANKOLE_FUNCTION_COMPUTE_TEST_CREDENTIALS_FILE`, `ANKOLE_FUNCTION_COMPUTE_TEST_IMAGE`, `ANKOLE_FUNCTION_COMPUTE_TEST_REPLACEMENT_IMAGE`, `ANKOLE_FUNCTION_COMPUTE_TEST_CP_PORT`, `ANKOLE_FUNCTION_COMPUTE_TEST_CP_ORIGIN`, and removing leftover templates afterward):
  ```bash
  MIX_TEST_PARTITION=function_compute_provider mix test integration/function_compute_worker_storage_test.exs --trace
  ```

## Keep design docs and the changelog current

Whenever a change alters subsystem behavior, schemas, protocols, or cross-domain contracts, update (or create) the owning specification under [`docs/design-docs/`](docs/design-docs/).

All timeless documentation (`README*`, `CONTRIBUTING.md`, `docs/`, `app/website/src/content/docs/`, and package `README.md` / `SPEC.md` files—everything except `CHANGELOG.md` and dedicated upgrade guides) must state the current system contract directly and read naturally for human engineers:

- **No diff-relative or upgrade-anchored phrasing**: Never write `after this upgrade`, `in this release`, `no longer`, `previously`, `retains its existing...`, `keeps its existing...`, or `remains unchanged`.
- **No negative-space residue**: Do not describe deleted routes, dropped columns, or abandoned designs in general documentation (record breaking upgrade steps in `CHANGELOG.md` and `docs/upgrades/` instead).
- **No prompt-constraint echoes**: Keep task-prompt disclaimers, internal test-coverage caveats, and cleanup TODOs out of user and architecture docs.
- **Cohesive structure and native localization**: Integrate new facts directly into the section that owns the topic rather than tacking patch paragraphs onto the bottom of a file, and write every localized document idiomatically in its target language rather than calquing English sentence structure.

### Changelog

`CHANGELOG.md` tells operators and users what changed for them in each release. Treat it as release history rather than a design specification—product behavior is governed by `docs/design-docs/` and explicit product decisions.

Include only changes that a user or operator can observe or must act on when upgrading: new capabilities, behavior changes, removals, fixes for user-facing bugs, and required upgrade steps. Omit documentation edits, website updates, test changes, dev tooling, dependency bumps, internal refactors, and similar non-user-facing work; if a release contains nothing user-visible, write a single bullet: `Internal changes only.`

Commits that touch **only** documentation (root `*.md` files, `docs/`, `app/website/`) or `CHANGELOG.md` itself do **not** add a changelog version. Every other commit on `main` must add (or update) one pending top-of-file version section (`## Version MAJOR.MINOR.PATCH (YYYY-MM-DD)`, newest first, written in concise plain language once implementation is complete), because the runtime-image release workflow tags the top version on each `main` push and refuses to reuse an already-published version. If `CHANGELOG.md` already has an uncommitted version header compared to `HEAD`, append your bullet to that pending version so all uncommitted worktree changes ship together. Changes confined strictly to `internals/` with zero FOSS impact belong in `internals/CHANGELOG.md` instead.

### Version selection

Bump `PATCH` by default. Bump `MINOR` (resetting `PATCH` to `0`) when a release adds a new user- or operator-facing capability, or when existing behavior requires an operator or caller to update configuration, stored data, or API calls (state that capability or required action clearly in the bullet). Bumping `MAJOR` or adding `-alpha`, `-beta`, or `-rc` suffixes requires an explicit human product decision (`alpha` and `beta` publish as GitHub pre-releases; `rc` publishes as a full release).

### Runtime image releases

On every push to `main` where `Repository checks` passes (and where changes since the previous release go beyond documentation), the runtime-image workflow reads the top version from `CHANGELOG.md`, builds and verifies the paired control-plane and Worker images, pushes immutable image tags, and creates the matching `vVERSION` GitHub Release using that exact changelog section (`alpha`/`beta` move the `canary` tag as pre-releases; `rc`/stable versions move `main-latest` as full releases). The workflow fails hard rather than reusing a version number, overwriting an existing image tag digest, or publishing release notes that diverge from `CHANGELOG.md`.

That same workflow builds `app/agent_computer/Dockerfile.base` and publishes `ghcr.io/agentbull/ankole-agent-os-base:REVISION`. Local Worker builds pull the prebuilt base image pinned in `app/agent_computer/base-image.lock` whenever `Dockerfile.base` matches that pinned commit, falling back to a local build when `Dockerfile.base` has changed. Because CI publishes the new base image only *after* a `Dockerfile.base` change lands on `main`, a commit editing `Dockerfile.base` cannot update `base-image.lock` in the same commit; once CI publishes the new base image, run `bun run kit pin-base-image` (which verifies that the target commit is an ancestor of `HEAD` with an identical `Dockerfile.base` and a published image) and commit the updated lockfile. Note that Codex, MCPorter, OfficeCLI, Typst, `kubectl`, and AWS CLI are installed in the outer Worker Dockerfile, so bumping their versions does not invalidate `Dockerfile.base`.

## Submit a pull request

1. Fork the repository and create a focused branch from `main`.
2. Make the smallest coherent change, with tests that exercise the real boundary.
3. Update design documentation and the changelog when required.
4. Run scoped checks first, then the applicable full gates and end-to-end suites.
5. Review `git diff` for unrelated files, generated churn, secrets, and stale comments.
6. Open a pull request with the problem, the chosen solution, validation evidence, and anything still unverified.

For a large or cross-subsystem proposal, open a GitHub issue first so ownership and direction can be aligned before implementation.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security vulnerabilities through [`SECURITY.md`](SECURITY.md), never through a public issue.
