# Contributing to Ankole

Thank you for contributing to Ankole. This guide is for both human contributors and coding agents, and it assumes no previous experience with Ankole, Elixir, Phoenix, Ecto, Rust, or OTP.

> [!WARNING]
> Ankole is in active development. Public APIs do not yet have a compatibility contract, so interfaces and subsystem boundaries can change between releases.

A site is one complete deployment. It can contain several tenants, each with its own people, Agents, Brain, and integrations. Site operators manage shared providers and infrastructure in the site administration Console at `/site-admin-console` (or the absolute path set in `ANKOLE_SITE_ADMIN_CONSOLE_PATH` before startup). Active Humans sign in on their tenant's slug host (locally, `http://<tenant-slug>.ankole.localhost:4000/`) through its configured identity providers, or start login from an OIDC application.

## Source builds

`ANKOLE_EDITION=foss|saas` is a build input. The default is `foss`, including
when the checkout contains `internals`. FOSS does not compile private modules,
read private configuration, or install private migrations. SaaS requires the
matching private source; a missing file or module fails the build.

Both forms use one Mix project, `:ankole` application, Repo, and database. They
have separate `_build/foss` and `_build/saas` trees. Vite assets and generated
locale catalogs also stay in those trees. Release assembly copies only the
selected assets and catalogs into its application directory. A release uses
those packaged paths and does not need the source checkout. Build tasks do not
use Turbo artifact caching; checks include the edition in their cache input.

The SaaS source has these required inputs:

- `internals/control_plane/config.exs` declares the HTTP entry, Host policy,
  AppConfigure definitions module, and trusted site identity sources.
- `internals/control_plane/lib` contains distinct private modules. It does not
  redefine public modules or add another OTP application.
- `internals/control_plane/test/test_helper.exs` accompanies the private tests.
  Mix runs both public and private test paths; support modules compile only in
  the test environment.
- `internals/webapps/entries.json` maps private entry names to relative source
  paths. Names cannot replace public entries. Private sources use the public
  webapp dependencies through a generated `node_modules` link. Entry reads do
  not create the link. Mix, Vite, type checks, and Bun test preparation create
  it and accept concurrent preparation of the same target. `lint`, type checks,
  and tests include both source sets.
- `internals/locales` supplies TOML catalogs. Build preparation merges them with
  public catalogs into generated JSON. Duplicate message keys fail the build.
  Phoenix, Vite development, production, and Bun tests read the same output.
- `internals/control_plane/priv/repo/migrations` contains private migrations.

`Ankole.Migrations` supplies the complete selected migration set to
`mix ecto.migrate`, `mix ecto.migrations`, `mix ecto.rollback`, and
`Ankole.Release.migrate/0`. Versions, filenames, and literal module names must
be unique across both directories, including files whose versions already ran.
SaaS releases place private files in `priv/repo/internal_migrations`, beside
public migrations. Both use the same `schema_migrations` ledger. Removing
private source does not reverse its schema changes.

From `app/control_plane`:

```bash
mix test
ANKOLE_EDITION=saas mix test
MIX_TEST_PARTITION=edition_build mix test integration/edition_build_test.exs --trace
```

The build integration test uses a labeled private fixture in a temporary
checkout. It checks FOSS isolation, SaaS compilation and resources, private test
discovery, empty and upgraded databases, rollback, and a detached release.
It does not implement or certify a SaaS account product.

A SaaS source image uses the public Dockerfile with a named private context:

```bash
docker build -f app/control_plane/Dockerfile \
  --build-arg ANKOLE_EDITION=saas \
  --build-context ankole-internals=./internals .
```

The internal resource image can also add private Agent resources to an
assembled image. Copying resources into that image does not compile a SaaS
backend. Use the source build for private server and frontend code.

## What a successful setup means

A full local setup is complete only when all of these are true:

1. Bun, Elixir/Erlang, Rust, Docker, and Docker Compose work from a new terminal.
2. The devkit PostgreSQL service is healthy and the control-plane database is migrated.
3. `bun dev` runs the Phoenix control plane, Web Console, and frontend assets. Agent creation requests Worker startup. Environment tools or Jobs request it again after idle release; pure questions do not wait for it.
4. The first administrator can sign in, and an LLM provider, agent, and Signal binding are configured.
5. A real message sent through Feishu/Lark reaches the agent and receives the expected reply.

A documentation-only or package-local change may not need the full Feishu path. State exactly which stage you reached and which stages you did not verify.

## How a coding agent should guide a human

The coding agent owns terminal work it can perform safely: inspecting the workspace, installing project dependencies, starting services, running checks, reading non-sensitive logs, and locating the first failing boundary.

The human owns account and trust decisions: entering passwords or secrets, signing in to external services, approving OAuth, creating and publishing a Feishu app, and approving destructive recovery.

Before starting, the agent should:

1. Read this file and [`AGENTS.md`](AGENTS.md) in full.
2. Confirm it is operating from the repository root.
3. Run `git status --short` and preserve unrelated changes.
4. Work through the setup stages in order and verify each stage before continuing.

The agent must pause when the human needs to:

- enter a system password or secret;
- complete a browser login, OAuth consent, or account-admin action;
- choose a provider, model, or external application policy;
- approve database rebuilds, Docker volume removal, or discarded files.

Never print the whole environment, open secret files without a concrete need, paste credentials into chat, or place credentials in commands that may be saved in shell history. Prefer the Console's secret fields.

Do not turn a failed full setup into a smaller success claim. Report the first broken stage, the evidence, the next safe action, and any step that remains unverified.

## Understand the local system

You do not need to learn every runtime before starting. The repository-level Bun commands select the correct working directory and coordinate the runtimes.

| Component | What it does | Source | Local surface |
| --- | --- | --- | --- |
| PostgreSQL | Stores all durable control-plane state | Devkit Compose service | `localhost:5433` |
| Control Plane | Runs setup, Console APIs, configuration, durable workflows, and runtime authority | `app/control_plane` | `http://ankole.localhost:4000` |
| Webapps | Provide setup, authentication, and Console pages | `app/webapps` | Vite on `localhost:3035`, served through the control plane |
| Agent Computer | Runs environment tools, Codex, Skill materialization, and Worker-local state | `app/agent_computer` | One Docker container per Agent, label `ankole.installation=dev` |
| Kernel | Provides native primitives and transport | `app/kernel` | Loaded by Elixir through Rustler and the browser daemon through Node-API |
| RuntimeFabric | Carries live control-plane-to-worker traffic over a Phoenix Channel | Control Plane | `ws://localhost:4000/runtime-fabric/worker` |

### Elixir in five minutes

`mix` is the Elixir task runner, Phoenix is the web framework, Ecto owns database access and migrations, ExUnit is the test framework, and OTP provides supervised processes.

Elixir implementation files use `.ex`; tests, scripts, and configuration often use `.exs`.

Domain and web code lives under `app/control_plane_core/lib`. The assembly, configuration, tests, and migrations remain under `app/control_plane`. Each control-plane Plugin is a local Mix project under `plugins/`; the matching provider client is part of that project.

Use the root Bun commands in this guide. Run `mix` directly only when a module-specific instruction says to, and then use `app/control_plane` as the working directory.

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

The script installs system build packages, Docker, stable Rust with `rustfmt` and `clippy`, the repository's Elixir/Erlang toolchain, and the Bun version pinned by the repository.

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

`bun --version` must match the `packageManager` version in `package.json`. Every other command must exit successfully, and `docker info` must connect to the daemon.

Do not continue while `docker info` fails. Fix Docker Desktop startup or Linux group permissions first.

**Stage 2 is complete when every tool check succeeds from a new terminal.**

## 3. Install dependencies and initialize PostgreSQL

Run these commands in order:

```bash
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
```

They perform distinct jobs:

1. `bun install` installs every workspace dependency.
2. `services:start` starts PostgreSQL through `tools/devkit/external-services.docker-compose.yml` and waits for it to become healthy.
3. `services:status` shows the Compose service state.
4. `control-plane:setup` fetches Elixir dependencies, creates the development database, runs Ecto migrations, and loads seeds.

The first Elixir compile is much slower than a normal TypeScript install. Continued compile output is progress; do not interrupt it only because it takes several minutes.

If a command fails, preserve its first actionable error. Do not jump to a database reset, edit generated files, or bypass the root command with an improvised lower-level command.

**Stage 3 is complete when PostgreSQL is healthy and `control-plane:setup` exits successfully.**

## 4. Start the complete development environment

Run:

```bash
bun dev
```

Keep this terminal open. The devkit starts or verifies PostgreSQL, creates and migrates the local database, builds a missing or stale Worker image, and starts Phoenix and the frontend assets with the Docker Worker provider. Agent creation requests a Worker container, which runs the local Agent Computer source in watch mode.

The first run may spend substantial time building the Agent Computer image. Wait while there is active build output.

In another terminal, verify the visible boundaries:

```bash
bun run services:status
curl -I http://ankole.localhost:4000/
```

The database must be healthy and the HTTP request must reach the control plane. Then open [`http://ankole.localhost:4000`](http://ankole.localhost:4000). Create an Agent and wait for its Worker to become ready. List the containers with `docker ps -a --filter label=ankole.installation=dev`. Initial image preparation can take time; the creation request does not wait for it. After idle release, an environment tool or Job requests the Worker again; pure questions do not wait for it.

The development control plane listens on every interface, because Worker containers reach it through the Docker bridge gateway (`host.docker.internal`). On a shared network, block port 4000 from other machines.

Do not start a second `bun dev`. Stop the control plane with `Ctrl+C` in the original terminal; the devkit then removes the Worker containers of the `dev` installation.

PostgreSQL intentionally remains running after `Ctrl+C`. Stop it separately when needed:

```bash
bun run services:stop
```

**Stage 4 is complete when the local site opens.**

## 5. Complete first-time product setup

This section includes the exact Feishu permissions, events, callbacks, and field values needed by the current local path. Follow the order because later screens depend on resources created earlier.

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
| `app/control_plane` | Phoenix/OTP control plane application: OTP entry points, release and upgrade modules, Mix tasks, configuration, migrations, and the test suites |
| `app/control_plane_core` | Domain and web code of the control plane: Ecto persistence, setup, Console APIs, and durable runtime authority |
| `app/agent_computer` | Bun/TypeScript Worker, environment tools, Codex, Skills, files, and terminal state |
| `app/kernel` | Rust library loaded through Rustler and browser Node-API bindings |
| `app/webapps` | Vite/React setup, authentication, Pod, and Console applications |
| `app/library` | Built-in agent skills and starter templates |
| `app/locales` | Shared translation catalogs |
| `libs/` | Shared UI, editor, and provider client libraries |
| `plugins/` | Trusted first-party plugins |
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

Start with checks scoped to the files you changed. This makes failures easier to attribute and avoids treating unrelated worktree noise as your regression.

The `Repository checks` workflow runs on pull requests and pushes to `main`.
Each job runs the existing commands of one area: `repo-lint` (root oxlint and
oxfmt), `webapps` (analysis, Webapps, and Applet SDK), `agent-computer` (type
check and host unit suite), `libs` (UI kit and devkit), `page-codec` (block
editor, the shared XML corpus in TypeScript and Rust, Kernel Node-API, and
browser unit tests), `kernel-lint` (rustfmt, clippy for each feature set, and
Rust unit tests), `mix-projects` (a matrix of the six provider client projects,
shared transport and frame libraries, fake Feishu server, and Kernel Elixir
tests as independent Mix projects), and `control-plane` (lint with Credo, the
compile-connected cycle check, OpenAPI output, fast suite, upgrade check, and
standalone Feishu protocol integration on the Ankole PostgreSQL image). Provider
E2E, Worker container tests, and browser integration suites still use their
dedicated commands. The runtime-image workflow releases a `main` push only after
this workflow succeeds for that revision.

| Changed area | Useful first checks |
| --- | --- |
| Documentation only | `git diff --check` and link/command inspection |
| Repository tooling or any TypeScript | `bun run lint:repo` and `bun run fmt:check:repo` |
| Control Plane | `bun run --filter @ankole/control-plane type-check` and `bun run control-plane:test` |
| Agent Computer | `bun run agent-computer:type-check` and `bun run agent-computer:test` |
| Webapps | `bun run webapps:type-check`, `bun run --filter @ankole/webapps test`, and `bun run webapps:build` |
| Kernel | `bun run --filter @ankole/kernel lint` and `bun run --filter @ankole/kernel test` |
| Browser | `bun run --filter @ankole/browser lint`, `bun run --filter @ankole/browser test`, and `bun run --filter @ankole/browser test:integration` with `ANKOLE_BROWSER_TEST_CHROMIUM` set to Chromium |
| Feishu client | `bun run lark-adapter:test` |
| Block editor | `bun run --filter @ankole/block-editor type-check`, `bun run --filter @ankole/block-editor test`, and `bun run --filter @ankole/block-editor test:package` |
| Website | `bun run --filter @ankole/website type-check` and `bun run --filter @ankole/website build` |

The website stays on TypeScript 6.0.3 while the other packages use TypeScript 7. `astro check` stops with an error on TypeScript 7.0, and `@astrojs/check` lists TypeScript 5 and 6 as its supported versions. Keep this pin when you update dependencies. Move the website to the workspace version when Astro supports it: `@astrojs/ts-content-mapper` needs TypeScript 7.1 or later.

For one Elixir test file, set the working directory to `app/control_plane` and run `mix test test/path/to/file_test.exs`. This is the normal case where a direct `mix` command is appropriate.

Control Plane lint runs the Credo default check set, ex_slop checks, and the
Ankole checks. Fix violations; there is no baseline exemption. The checks that
`app/control_plane/.credo.exs` lists as `disabled` had findings when the default
set was switched on; enable one again in the change that removes its findings.
The nesting limit is 4 and the cyclomatic complexity limit is 20.
`bun run analyze:unused` checks production files, exports, types, and
dependencies; tests do not retain dead production code.

The build applies the pinned Ash 3.36.1 and AshPostgres 2.15.1 patches before
dependency compilation. The build needs `patch`; the Docker build installs it.
A failed patch stops the build. The fixes prevent false notification warnings
and handle skipped upserts whose row is not visible in the selected tenant.
Check the public action behavior when updating these dependencies. Remove each
patch when an upstream release includes its fix.

Credo checks that bulk actions use `Ankole.Ash` and that resource mutation
filters use `change(filter(...))`. Resource compilation checks the tenant and
transaction contracts. Database tests check the resulting isolation and writes.

After you change compile-time dependencies, run this check from
`app/control_plane`:

```bash
MIX_ENV=test ANKOLE_EDITION=foss mix ankole.compile_cycles
MIX_ENV=prod ANKOLE_EDITION=foss mix ankole.compile_cycles
```

The command checks the host and every local Mix dependency. It rejects dependency cycles that contain a compile-time dependency.
Runtime-only cycles remain allowed. CI checks both test and production builds
of the FOSS edition. Production uses compile-time plug initialization, so a
test build alone cannot detect all compile dependencies. Endpoint and Router
use local function plugs for business implementations and keep the standard
library plug initialization. The private SaaS router uses
`AnkoleWeb.runtime_forward` to retain Phoenix forwarding and record its target
as a runtime dependency. Check both environments with `ANKOLE_EDITION=saas`
when private control plane sources are present. Do not add `--only-direct`:
it removes indirect paths that can close a compile-connected cycle.

Run the Driver's process and transaction checks separately from the unit suite.
Use a separate test partition and a resolvable local node name:

```bash
cd app/control_plane
MIX_TEST_PARTITION=session_driver elixir --sname session_checks@localhost -S mix test integration/session_driver_test.exs
```

`bun run test:integration` in `app/control_plane` runs every integration file
that needs only PostgreSQL. It excludes the `cloud`, `cluster` (a named node),
and `external` (Docker, Kubernetes, or cloud tooling) tags; run those files with
the commands later in this guide.

`bun run agent-computer:test` runs Agent Computer unit tests on the host. The
host needs Bun, Bash, GNU `timeout`, and Python 3. In `app/agent_computer`,
`bun run test:integration` runs portable integration tests on the host with
Codex 0.163.0, MCPorter 0.14.3 running with Bun, native `apply_patch`, and GNU
`stat` (`gstat` on macOS). `ANKOLE_CODEX_BINARY` can select a local Codex binary.
The command sets `TMPDIR=/tmp` to keep Unix socket paths short.

On Linux, also run `bun run test:integration:linux`. It checks the supervisor
and managed Codex runtime with `setsid` and util-linux `flock` (`-F` support).
`bun run test:integration:docker` checks the Worker entrypoint, image
configuration, `tini`, pinned Codex bindings, browser, OCR, and installed Lark
CLI. `bun run test:docker` runs the unit suite in the image. Only the Docker
commands require Docker and a current Worker image.

### Pod content checks

The Pod domain tests are under `test/ankole/pod`. Dedicated integration files
check concurrent page moves, interrupted purge, tenant teardown, and 100,000-row
Database queries with committed PostgreSQL transactions. Use a separate test
partition. The GitHub sync file has the `external` tag and makes a read-only
request to the public GitHub API; run it explicitly when network access is
available.

The real-browser check uses the production Pod and SDK with three authenticated
identities. In separate terminals, run:

```bash
# Build the production frontend assets.
cd app/webapps
bun run build
```

```bash
# Create a dedicated browser-test database and start its authenticated fixture.
cd app/control_plane
MIX_ENV=test MIX_TEST_PARTITION=pod_browser mix ecto.create
MIX_ENV=test MIX_TEST_PARTITION=pod_browser mix ecto.migrate
MIX_ENV=test MIX_TEST_PARTITION=pod_browser \
  POD_BROWSER_STATE_PATH=/tmp/ankole-pod-browser.json \
  mix run --no-start integration/support/pod_browser_server.exs
```

```bash
cd app/webapps
POD_BROWSER_STATE_PATH=/tmp/ankole-pod-browser.json bun run test:pod
```

The fixture binds `127.0.0.1:4000` by default. Set `POD_BROWSER_PORT` and use a
distinct `pod_browser_`-prefixed test partition to run beside another fixture.
It serves the built production assets on
`http://<tenant-slug>.ankole.localhost:4000`. The state file supplies that canonical
`base_url` and the site's shared account proof cookies; use it rather than navigating to the bind
address or adding `tenant_id` to a URL. Stop another local server on that port
before starting it. Each fixture start
creates a new tenant and writes test identities to the state file with mode
`0600`. Treat that file as credentials and remove it after the check. The browser database
uses the normal connection pool so channel processes do not keep SQL Sandbox
checkouts. The test does not bypass endpoint or page authorization. It covers
live edits, tables, Applet publication, access revocation, and Office previews.
Its independent sample-reservation workspace uses the production native Applet
backend and committed records. The backend story checks pending submission,
retained inputs after rejection, viewer write denial, competing reservations,
and revision-paired frontend/backend replacement. It delays delivery of one
real committed response to inspect pending UI; it does not replace that write.
Run `test:garfish` separately for sandbox effects and entry-style scoping.

### Full local quality gate

Before pushing a broad code change, run:

```bash
bun run lint
bun run type-check
bun run fmt:check
bun run analyze
bun run test
git diff --check
```

`bun run fmt` changes files in place.

If the full workspace has an unrelated failure, keep the scoped validation result separate and report the exact ambient blocker. Do not weaken a test or bypass a production path to make the aggregate command green.

### End-to-end suites

The dedicated runner builds a missing or stale worker image and starts PostgreSQL when needed:

```bash
tools/e2e/run --help
tools/e2e/run
tools/e2e/run --perf
tools/e2e/run --chaos
tools/e2e/run --real-provider --providers=available
tools/e2e/run --real-llm
tools/e2e/run --all
```

These suites are slower and are not part of the default fast path. Run the mode that protects the changed boundary; real-provider and real-LLM modes require the relevant test credentials.

The gate includes a real Compose upgrade from the pooled release pinned in
`tools/e2e/pooled-worker-revision`. It pulls that release's images and builds
the current control-plane image. To use an image already built from the
current source and resolved Worker image, set `ANKOLE_E2E_CONTROL_PLANE_IMAGE`.
This is required for the Compose scenario with `--no-build`. To run only that
scenario, use `tools/e2e/run --gate --only=compose_upgrade`.

The chaos suite's idle and image replacement scenarios use real database
transactions and wait for the five-minute Worker demand window to end. Do
not run another suite against the same database partition at the same time.

For the Pod collaboration story, run:

```bash
tools/e2e/run --real-llm --only=pod_content_real_llm
```

This selection runs four stories with real models and Docker Workers. A Human
uses browser Chat to request a report, typed sales table, formula, and applet;
follows the saved Page link; adds a sale in the published applet; and requests
an update through Page Chat without repeating the Page identity. The check
reads the saved content and data, revokes Agent access, and deletes the
Conversation while retaining its Pages. Another story develops a pure frontend
SPA, exercises it in the browser, and verifies Agent-created and moved Pages.
The Agent moves the original Page with space `edit` access and no permission
upgrade. The move must preserve access to the Page and its subpages.
The short move can finish directly in Main or through a real Job.
The research story invokes the installed research Skill without specifying an
output format and requires an editable Page linked from Chat. Individual tags
are `pod_content_browser_report`, `pod_content_pure_spa`,
`pod_content_research`, and `pod_applet_backend`. The backend story asks a real
Agent to build and publish a sample-reservation Applet, uses its POST route in
the browser, checks the saved caller-attributed write and retained failed
quantity, and requests an update to the same Applet. These checks require the existing OpenRouter test
credentials and production frontend assets. A successful Job report alone is
not proof that the requested content was saved.
Long-lived browser channels use the normal SQL connection pool; the suite
deletes its committed fixtures and restores the test pool after cleanup.

For the DeepSeek user stories and recovery checks, select these tags:

```bash
tools/e2e/run --real-llm --only=deepseek_release_stories
tools/e2e/run --real-llm --only=deepseek_clarification_flow
ANKOLE_REAL_LLM_E2E=1 tools/e2e/run --chaos --only=real_llm_chaos
tools/e2e/run --real-llm --only=deepseek_delivery_chaos
ANKOLE_REAL_LLM_E2E=1 tools/e2e/run --gate --only=real_llm_compose_chaos
```

These selections use `deepseek/deepseek-v4.1-flash` through OpenRouter and
FakeFeishu transport. Computer scenarios use real Docker Workers; direct
replies, Skill views, and clarification do not require a computer.
Set `OPENROUTER_API_KEY` or
`OPEN_ROUTER_API_KEY` through the existing test credential configuration.
The first four run the control plane in the test BEAM. The Compose selection
runs the control plane and PostgreSQL in containers, stops the complete
control plane, restarts PostgreSQL, and waits for production reconciliation.
It uses the same image preflight as `compose_upgrade`.

Check the stored file contents, the number of effects, and the platform-visible
reply or attachment. A model's completion text alone does not prove delivery
or recovery. After Worker process loss, an unsafe tool with an unknown result
must return an interrupted result. Inspect the authoritative effect before
repeating it; only a declared retry-safe call can run again automatically.
The clarification scenario checks the visible choices and an ordinary WS
reply that continues the same conversation. An ordinary reply supersedes
the old interaction; only managed interaction callbacks record it as answered.

The local kind user-flow suite below uses fake Feishu and a fake model. Its
Kubernetes, Worker, and storage checks do not establish real model behavior.
FakeFeishu observations also do not prove the real Feishu service or web UI.

The conversation driver suite also uses two named BEAM nodes with PostgreSQL.
It checks one writer, epoch fencing, settings invalidation, remote routing, and
recovery after planned node shutdown. Its model provider and Worker channel
are test fakes; the Docker suites check the real Worker separately.

```bash
cd app/control_plane
MIX_TEST_PARTITION=conversation_loop_cluster \
  elixir --sname ankole_session_checks@localhost -S mix test \
  integration/session_driver_test.exs --trace
```

### Worker provider checks

The Docker and kind suites call the production provider adapters. They delete
instances, attach the same storage to new instances, check files, and delete
storage. The lifecycle suites also call the real platform APIs and interrupt
the coordinator to check recovery and row locks. The provider transaction
suite uses concurrent PostgreSQL transactions to check seed import and default
selection. These checks do not replace the full user flow in `tools/e2e/run`.
The kind user-flow suite uses the real Worker Channel, AIGateway, command and
file tools, and Kubernetes provider with fake Feishu and model services. It
checks a reply, file retention after Pod deletion, a reply from the replacement,
and Agent deletion with both storage layouts.
Run them separately from the fast suite and do not run two `mix test` commands
against the same database partition at the same time.

With Docker, Helm, kubectl, and kind installed, run these commands from the
repository root. The kind cluster and NFS fixture are for local tests only.
Always pass the temporary kubeconfig; do not use a cloud cluster context.
kind gives the node the `HTTP_PROXY` and `HTTPS_PROXY` of your shell. A proxy
on a loopback address does not work in the node, and the NFS fixture image
cannot be pulled; for `kind create cluster`, use an address that the node can
reach, such as `http://host.docker.internal:<port>` on Docker Desktop.

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

The kind suite uses `standard` for exclusive local-path PVCs and `example-nfs`
for a shared NFS PVC. Its fixture pins NFS-Ganesha 4.0.8 and uses NFS 4.0; see
the source and kernel compatibility note in the fixture. These checks do not
cover CSI block storage or recovery after a node fails. The Helm suite also
checks the internal chart when that checkout is present.
For an approved EFS check, use a separate kind cluster and a dedicated EFS
test directory. Replace the NFS fixture with a static RWX NFS PV and a
`kubernetes.io/no-provisioner` StorageClass named `example-nfs`. Set the PV's
storage class to `example-nfs`, capacity to `128Mi`, reclaim policy to `Retain`,
and mount options to `vers=4.1` and `hard`. The node must reach the EFS mount
target. Run the same `kubernetes_worker_storage_test.exs` without changing its
assertions. If a TCP tunnel supplies a different NFS port, set `port` only;
do not set `mountport`, because EFS does not provide the NFSv3 mount service.
Afterward, remove the test PV, cluster, and EFS resources. This check does not
exercise the EFS CSI driver or access-point identity mapping.
The user-flow suite needs Pods to reach the host control plane through
`host.docker.internal`, as provided by Docker Desktop.

The Cloudflare storage check needs a dedicated adapter, R2 bucket, and two
different digest-pinned amd64 images in that adapter. It runs two real Workers
and uses the real control-plane Channel and file relay. It checks same-generation
creation, provider isolation, file restore after instance deletion and image
replacement, and Agent deletion. It does not use an LLM or prove the full user
flow. Obtain approval for the cloud resources and image uploads first.

Provide these values only for the approved run:

- `ANKOLE_CLOUDFLARE_TEST_ADAPTER_URL` and `ANKOLE_CLOUDFLARE_TEST_ADAPTER_TOKEN`.
- `ANKOLE_CLOUDFLARE_TEST_IMAGE` and
  `ANKOLE_CLOUDFLARE_TEST_REPLACEMENT_IMAGE`: the two deployed image names.
- `ANKOLE_CLOUDFLARE_TEST_CP_PORT`: a free local port for the test control plane.
- `ANKOLE_CLOUDFLARE_TEST_CP_ORIGIN`: an approved public HTTPS origin that
  forwards to that port, with no trailing slash. It must carry WebSockets and
  the file relay. Use a separate test database.

```bash
cd app/control_plane
MIX_TEST_PARTITION=cloudflare_worker_provider mix test \
  integration/cloudflare_worker_storage_test.exs --trace
```

The check deletes its Agents through the coordinator. If cloud cleanup fails,
it keeps the unresolved Worker rows and provider credentials in the test
database. Keep that database until the instances and storage are deleted.
Remove the adapter, bucket, uploaded images, and public forwarding endpoint
after the approved checks. This check does not cover a forced platform stop,
a Durable Object restart, or direct inspection of R2 objects after deletion.

The Lambda entry check runs the production Worker image against a local Linux
kernel NFS server. It verifies NFS 4.1, the root Worker identity, uid 1000 file
access, directory isolation, real container deletion and image replacement,
and repeated deletion hooks. It
does not call AWS or prove EFS behavior through suspension. Docker must support
privileged Linux containers and kernel NFS:

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

The Function Compute contract-file check also runs the production entry in
Linux. It checks admission gating, the root Worker identity, removal of sudo,
and repeated Worker and deletion contracts. It also checks that writable Home
ownership stays unchanged and a read-only Home stops startup. It does not call
Aliyun or envd:

```bash
cd app/control_plane
ANKOLE_WORKER_PROVIDER_TEST_IMAGE=$(cat /tmp/ankole-worker-image) \
  MIX_TEST_PARTITION=worker_provider mix test integration/function_compute_worker_bootstrap_test.exs --trace
```

The Vercel and Lambda cloud checks use the production coordinator, Channel,
and file relay. They are separate from the local and default suites. Prepare
only approved temporary resources and keep credentials in temporary files
outside the repository. Both need two different target images and a reachable
HTTPS/WebSocket test control plane. They preserve unresolved rows if cleanup
fails; retain the test database until cleanup is complete.

Vercel requires the `vercel-worker-provider` Control Plane Plugin. Function
Compute requires `china-market-ai-providers`. Before running either cloud
suite, save its Plugin ID in `plugins.enabled_ids` in that suite's database
partition and restart the test process. Keep the Plugin enabled through Agent
and storage cleanup. The suite checks this activation policy before cloud I/O.

- Vercel: `ANKOLE_VERCEL_TEST_TOKEN_FILE`, `ANKOLE_VERCEL_TEST_TEAM_ID`,
  `ANKOLE_VERCEL_TEST_PROJECT_ID`, `ANKOLE_VERCEL_TEST_REGION`,
  `ANKOLE_VERCEL_TEST_IMAGE_REPOSITORY`, `ANKOLE_VERCEL_TEST_IMAGE`,
  `ANKOLE_VERCEL_TEST_REPLACEMENT_IMAGE`, `ANKOLE_VERCEL_TEST_CP_PORT`, and
  `ANKOLE_VERCEL_TEST_CP_ORIGIN`. Images must be ready digests in VCR. The check
  creates two providers, sandboxes, and Drives and removes them afterward.
  The default session timeout is 24 hours. Set
  `ANKOLE_VERCEL_TEST_SESSION_TIMEOUT_SECONDS=2700` for an account with a
  45-minute limit. This sets the provider's `sessionTimeoutSeconds` value.
- Lambda: `ANKOLE_LAMBDA_TEST_CONFIG_FILE` contains provider YAML;
  `ANKOLE_LAMBDA_TEST_CREDENTIALS_FILE` contains a JSON object with temporary
  `accessKeyId`, `secretAccessKey`, and `sessionToken` values. Also set
  `ANKOLE_LAMBDA_TEST_IMAGE`, `ANKOLE_LAMBDA_TEST_REPLACEMENT_IMAGE`,
  `ANKOLE_LAMBDA_TEST_CP_PORT`, and `ANKOLE_LAMBDA_TEST_CP_ORIGIN`. Prepare the
  S3 build bucket, build IAM role, EFS root, VPC connector, and NAT access.
  The check builds provider images, creates MicroVMs and EFS directories,
  exercises suspend/resume, and deletes its Agents through the coordinator.
  Read the account's applied ARM64 memory quota with `GetServiceQuota` before
  the flow starts. This flow has two Agents. Each replacement waits for its
  old Worker to terminate, and a deletion helper replaces its terminated
  Worker. It needs room for two instances at the configured size:
  at least 8 GiB with the default 4 GiB size, after other account usage.
  Supported sizes are 4096 and 8192 MiB. A deletion helper reports success
  after file removal. The coordinator then requests its deletion. Wait for AWS
  to report `TERMINATED` before using that allocation for another instance.
  Remove the tagged images, S3 build objects, and supporting cloud resources
  after the instances have terminated. A local Docker check cannot prove this
  cloud path.

Run one command at a time from `app/control_plane` with a separate database:

```bash
MIX_TEST_PARTITION=vercel_worker_provider mix test integration/vercel_worker_storage_test.exs --trace
MIX_TEST_PARTITION=lambda_worker_provider mix test integration/lambda_worker_storage_test.exs --trace
```

The Function Compute cloud check uses the same coordinator, Channel, and file
relay. It needs an account with second-generation memory pause enabled. Run
it once with AgenticFS and once with OSS; one storage layout does not prove
the other. Set `ANKOLE_FUNCTION_COMPUTE_TEST_CONFIG_FILE` to provider YAML and
`ANKOLE_FUNCTION_COMPUTE_TEST_CREDENTIALS_FILE` to a temporary JSON file with
the provider's credential fields. Also set `ANKOLE_FUNCTION_COMPUTE_TEST_IMAGE`,
`ANKOLE_FUNCTION_COMPUTE_TEST_REPLACEMENT_IMAGE`,
`ANKOLE_FUNCTION_COMPUTE_TEST_CP_PORT`, and
`ANKOLE_FUNCTION_COMPUTE_TEST_CP_ORIGIN`. Both image versions must exist in
the configured ACR Enterprise repository. The test checks memory resume,
instance deletion, image replacement, provider isolation, and storage deletion.
The OSS run keeps the instance paused for 90 seconds, then checks that the
first retained-file read completes within 30 seconds. A short pause can leave
the old TCP connections usable and miss a storage recovery failure.
Remove its remaining templates after cleanup.

```bash
MIX_TEST_PARTITION=function_compute_provider mix test integration/function_compute_worker_storage_test.exs --trace
```

The Kubernetes shared-PVC cleanup must also be checked on the target NFS
server and EFS using NFS 4.1, including the rename under `.deleted/` and the
removal. Neither the kind NFS 4.0 fixture nor the local Lambda entry check
proves that production path.

## Keep design docs and the changelog current

A significant or cross-subsystem change should update or add a document under [`docs/design-docs/`](docs/design-docs/).

All timeless documentation (`README*`, `CONTRIBUTING.md`, `docs/`, `app/website/src/content/docs/`, and package `README.md` or `SPEC.md` files, except dedicated upgrade guides and `CHANGELOG.md`) describes the current system state directly:

- Do not use temporal or diff-relative phrasing (`after this upgrade`, `in this release`, `no longer`, `previously`, `retains its existing...`, `keeps its existing...`, `remains unchanged`).
- Do not document deleted routes, removed columns, or abandoned alternatives in negative space (for example, do not write that an obsolete route returns 404 in a general guide; record upgrade changes in `CHANGELOG.md` and the upgrade guide).
- Do not echo task-prompt constraints, internal test-coverage disclaimers, or cleanup TODOs into user or architecture documentation.
- Integrate new facts into the section that owns the topic instead of appending patch paragraphs to the bottom of a file or after `## Rules`. Keep every localized document in its target language.

### Changelog

`CHANGELOG.md` tells the people who run and use Ankole what a release changes for them. It is history, not an authority for product behavior or design; the owning design document or an explicit human decision is.

Record only what a user or an operator notices after the upgrade: a new capability, changed behavior, a removal, a fix for a failure that they could have met, and any action that the upgrade requires. Do not record documentation, the website, tests, tooling, dependency updates, refactors, or other internal work. When a version has no such change, its only bullet is `Internal changes only.`

A commit that changes only documentation (root `*.md` files, `docs/`, `app/website/`) or the changelog itself adds no version. Every other commit adds exactly one version at the top of the file, because the runtime-image workflow releases the newest version of each `main` push and refuses to reuse a version for another commit. Write the entry when the work is complete. When the changelog already differs from `HEAD`, add to that pending version; all uncommitted work in the worktree goes into the same next commit. A change confined to `internals/` that does not affect FOSS goes only in `internals/CHANGELOG.md`.

Use the heading `## Version MAJOR.MINOR.PATCH (YYYY-MM-DD)`, newest first, with a few short bullets in plain language.

### Version selection

Increment `PATCH` by default. Increment `MINOR` and reset `PATCH` to `0` when a user or an operator can do something that the product could not do before, or when existing behavior stops working until a person changes configuration, stored data, or an external caller; the bullet states that capability or action. `MAJOR` and the `-alpha`, `-beta`, and `-rc` suffixes follow an explicit human decision. `alpha` and `beta` publish as pre-releases; `rc` is a release.

### Runtime image releases

The runtime-image workflow runs for a `main` push after `Repository checks` succeeds for that revision, and skips a revision whose only changes since the last release are documentation. The newest changelog version is the release identity. After the control-plane and Worker image pair passes verification, the workflow adds immutable version tags and creates the matching `vVERSION` GitHub Release from that exact changelog section. An `alpha` or `beta` version publishes as a GitHub pre-release and moves `canary`; an `rc` or stable version publishes as a full release and moves `main-latest`.

The workflow must fail rather than reuse a version for another commit, replace an existing image tag with another digest, or publish release notes that differ from the changelog.

The same workflow publishes the Agent OS base, built from `app/agent_computer/Dockerfile.base`, as `ghcr.io/agentbull/ankole-agent-os-base:REVISION`. Local Worker builds use the base that `app/agent_computer/base-image.lock` pins when the working tree's `Dockerfile.base` matches that commit. When the recipe differs, devkit builds the base from the current file. A commit that changes `Dockerfile.base` cannot pin its own base, because the workflow publishes that base only after the push. After the workflow publishes the base of that commit, run `bun run kit pin-base-image` and commit the lock. The command pins the base of `HEAD` or of a commit that you give. It accepts only a commit in the history of `HEAD` that has the `Dockerfile.base` of `HEAD` and a published base. Codex, MCPorter, OfficeCLI, Typst, kubectl, and the AWS CLI are installed by the Worker image, so a version change does not change the base recipe.

## Submit a pull request

1. Fork the repository and create a focused branch from `main`.
2. Make the smallest coherent change, with tests that exercise the real boundary.
3. Update design documentation and the changelog when required.
4. Run scoped checks first, then the applicable full gates and end-to-end suites.
5. Review `git diff` for unrelated files, generated churn, secrets, and stale comments.
6. Open a pull request with the problem, the chosen solution, validation evidence, and anything still unverified.

For a large or cross-subsystem proposal, open a GitHub issue first so ownership and direction can be aligned before implementation.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security vulnerabilities through [`SECURITY.md`](SECURITY.md), never through a public issue.
