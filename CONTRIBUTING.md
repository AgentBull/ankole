# Contributing to Ankole

Thank you for contributing to Ankole. This guide is for both human contributors and coding agents, and it assumes no previous experience with Ankole, Elixir, Phoenix, Ecto, Rust, or OTP.

> [!WARNING]
> Ankole is in active development. Public APIs do not yet have a compatibility contract, so interfaces and subsystem boundaries can change between releases.

## What a successful setup means

A full local setup is complete only when all of these are true:

1. Bun, Elixir/Erlang, Rust, Docker, and Docker Compose work from a new terminal.
2. The devkit PostgreSQL service is healthy and the control-plane database is migrated.
3. `bun dev` runs the Phoenix control plane, Web Console, frontend assets, and one Docker Agent Computer worker.
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
| Control Plane | Runs setup, Console APIs, configuration, durable workflows, and runtime authority | `app/control_plane` | `http://localhost:4000` |
| Webapps | Provide setup, authentication, and Console pages | `app/webapps` | Vite on `localhost:3035`, served through the control plane |
| Agent Computer | Runs model turns, tools, skills, and worker-local state | `app/agent_computer` | Docker container `ankole-dev-agent-computer` |
| Kernel | Provides shared native primitives and RuntimeFabric transport | `app/kernel` | Loaded by Elixir and Bun |
| RuntimeFabric | Carries live control-plane-to-worker traffic | Control Plane and Kernel | `localhost:6010` |

### Elixir in five minutes

`mix` is the Elixir task runner, Phoenix is the web framework, Ecto owns database access and migrations, ExUnit is the test framework, and OTP provides supervised processes.

Elixir implementation files use `.ex`; tests, scripts, and configuration often use `.exs`.

Control-plane code lives under `app/control_plane/lib`, tests under `app/control_plane/test`, and migrations under `app/control_plane/priv/repo/migrations`.

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

1. `bun install` installs every workspace dependency and runs the root `prepare` script, which points `core.hooksPath` at `.githooks`.
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

Keep this terminal open. The devkit starts or verifies PostgreSQL, creates and migrates the local database, builds a missing or stale worker image, starts Phoenix and the frontend assets, and starts one managed Docker worker.

The first run may spend substantial time building the Agent Computer image. Wait while there is active build output.

In another terminal, verify the visible boundaries:

```bash
bun run services:status
curl -I http://localhost:4000/
docker ps --filter name=ankole-dev-agent-computer
```

The database must be healthy, the HTTP request must reach the control plane, and the worker container must be running. Then open [`http://localhost:4000`](http://localhost:4000).

Do not start a second `bun dev`. Stop the managed control plane and worker with `Ctrl+C` in the original terminal.

PostgreSQL intentionally remains running after `Ctrl+C`. Stop it separately when needed:

```bash
bun run services:stop
```

**Stage 4 is complete when the local site opens and the managed worker container stays running.**

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
http://localhost:4000/sessions/oidc/lark-main/callback
```

Replace `<APP_ID>` in the first URL with this application's real App ID. Do not paste the placeholder literally.

The second URL is the OIDC callback sent by the current setup flow. Feishu requires an exact match between the request's `redirect_uri` and the allowlist.

Keep these identities consistent:

- identity provider ID: `lark-main`;
- OIDC callback: `http://localhost:4000/sessions/oidc/lark-main/callback`;
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
2. **Agent.** Open Agents and create a stable UID, display name, and role. Configure `primary`, `light`, and `heavy` model profiles. One provider and model can temporarily serve all three.
3. **Signal binding.** Open Signals, select the agent and Feishu/Lark adapter, use `lark-main` as the binding name and principal namespace, enter the same app credentials and Feishu domain, then save and enable it.
4. **Worker.** Open Workers and confirm `local-dev-worker` is ready.

For a first group-chat smoke test, use `addressed_only`. It responds only when the bot is explicitly mentioned and needs fewer Feishu permissions than the full-message modes.

The identity provider and Signal binding are separate boundaries. Entering the same App ID and App Secret twice is expected; it does not require two Feishu apps.

If you need the financial MCP, add `BULLX_FINANCIAL_DATA_MCP_API_KEY` through the Console's encrypted worker-environment surface. Test it in a new agent turn after saving.

**Stage 5 is complete when the administrator can sign in, the provider and agent are usable, the Signal binding is enabled, and `local-dev-worker` is ready.**

## 6. Prove the end-to-end path

Before sending a message, confirm:

- the Feishu app's latest version is published;
- the test user is in the availability scope;
- the bot is present in the test chat;
- the provider is usable and the agent has all three model profiles;
- the Signal binding is enabled;
- `local-dev-worker` is ready.

Send `Please reply with LOCAL_OK only` in a direct chat with the bot. In a group using `addressed_only`, mention the bot and send the same request.

The reply must travel through the real path:

```text
Feishu event -> long connection -> Signal binding -> Agent -> LLM provider
              <- CardKit/message <- Signal binding <- Agent Computer
```

The setup passes only when Feishu shows `LOCAL_OK` from the configured agent and the `bun dev` terminal has no provider, permission, event, or worker error for that turn.

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
curl -I http://localhost:4000/
lsof -nP -iTCP:4000 -sTCP:LISTEN
lsof -nP -iTCP:3035 -sTCP:LISTEN
lsof -nP -iTCP:6010 -sTCP:LISTEN
```

Resolve the first process conflict or compile failure. Do not change the documented ports without also updating every dependent callback and worker endpoint.

### The activation code is missing

Click reprint, inspect the `bun dev` terminal, then use `bun run kit show bootstrap-activation-code`. Do not guess the code from browser internals or database rows.

### Feishu reports a redirect mismatch

Confirm that the browser origin, provider ID, and Feishu allowlist produce exactly:

```text
http://localhost:4000/sessions/oidc/lark-main/callback
```

### Login works but the bot does not reply

Check these boundaries in order:

1. The latest Feishu app version is published and the bot capability is enabled.
2. The test user and chat are in scope, and the bot is in the chat.
3. Message, CardKit, event, and callback permissions are active.
4. The Signal binding is enabled and points to the intended agent.
5. The agent has usable model profiles and the provider credentials are valid.
6. `local-dev-worker` is ready.

Inspect recent worker output without dumping its environment:

```bash
docker logs --tail 200 ankole-dev-agent-computer
```

If the primary model profile is unavailable, inspect the Console's Agents and Providers pages before blaming Feishu ingress.

### A newly saved worker secret is unavailable

Worker environment changes are injected into new turns. Send a new message after saving the value; do not use an already-running turn to judge the change.

## Work on a contribution

Read [`AGENTS.md`](AGENTS.md) before editing. It defines repository-wide ownership boundaries, objective fidelity, test discipline, dependency policy, and the required changelog workflow.

Before changing a subsystem:

1. Inspect `git status --short` and preserve unrelated work.
2. Read the nearest README, design doc, and existing implementation.
3. Search for the established pattern before adding another abstraction.
4. Identify what can be deleted or reused before adding code.
5. Choose the smallest tests that exercise the real changed boundary.

Do not add a dependency without explicit approval. Do not preserve obsolete names or compatibility paths unless a real current caller requires them.

### Repository map

| Path | Responsibility |
| --- | --- |
| `app/control_plane` | Phoenix/OTP control plane, Ecto persistence, setup, Console APIs, and durable runtime authority |
| `app/agent_computer` | Bun/TypeScript worker, model loop, tools, skills, files, and terminal state |
| `app/kernel` | Shared Rust crate loaded through Rustler and N-API |
| `app/webapps` | Vite/React setup, authentication, and Console applications |
| `app/library` | Built-in agent skills and starter templates |
| `app/locales` | Shared translation catalogs |
| `libs/` | Shared UI and provider client libraries |
| `plugins/` | Trusted first-party plugins |
| `tools/devkit` | Repository automation, local services, database helpers, and analysis |
| `tools/e2e` | Dedicated integration and end-to-end suites |
| `docs/design-docs` | Current design intent for non-trivial subsystems |

PostgreSQL owns durable truth, the Elixir control plane owns commit authority and supervision, the Rust kernel owns shared native primitives and transport, and Agent Computer owns execution and worker-local state.

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

| Changed area | Useful first checks |
| --- | --- |
| Documentation only | `git diff --check` and link/command inspection |
| Control Plane | `bun run --filter @ankole/control-plane type-check` and `bun run control-plane:test` |
| Agent Computer | `bun run agent-computer:type-check` and `bun run agent-computer:test` |
| Webapps | `bun run webapps:type-check`, `bun run --filter @ankole/webapps test`, and `bun run webapps:build` |
| Kernel | `bun run --filter @ankole/kernel lint` and `bun run --filter @ankole/kernel test` |
| Feishu client | `bun run feishu-openapi:test` |

For one Elixir test file, set the working directory to `app/control_plane` and run `mix test test/path/to/file_test.exs`. This is the normal case where a direct `mix` command is appropriate.

The Agent Computer runs only in its Linux image. Its test command uses the devkit Docker path and requires Docker plus a current worker image.

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

`bun run fmt` changes files in place. If a `.githooks/pre-commit` hook exists in your checkout, it still does not replace the quality gate.

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
tools/e2e/run --brain-real-llm
```

These suites are slower and are not part of the default fast path. Run the mode that protects the changed boundary; real-provider and real-LLM modes require the relevant test credentials.

`--all` excludes the dedicated Brain real-model acceptance path, so run `--brain-real-llm` explicitly when the change requires it.

## Keep design docs and the changelog current

A significant or cross-subsystem change should update or add a document under [`docs/design-docs/`](docs/design-docs/). Explain the chosen contract and ownership boundary, not abandoned drafting alternatives.

Every completed change updates the root [`CHANGELOG.md`](CHANGELOG.md). One Git commit corresponds to exactly one changelog version.

Before editing the changelog, inspect its staged and unstaged state:

```bash
git status --short CHANGELOG.md
git diff -- CHANGELOG.md
git diff --cached -- CHANGELOG.md
```

If `CHANGELOG.md` is already modified, append the new summary to the latest pending version. If it is clean relative to `HEAD`, add the next `YY.MM.N` version for the current month.

Write one outcome-focused bullet. Describe user-visible behavior or the preserved system guarantee rather than listing files.

## Submit a pull request

1. Fork the repository and create a focused branch from `main`.
2. Make the smallest coherent change, with tests that exercise the real boundary.
3. Update design documentation and the changelog when required.
4. Run scoped checks first, then the applicable full gates and end-to-end suites.
5. Review `git diff` for unrelated files, generated churn, secrets, and stale comments.
6. Open a pull request with the problem, the chosen solution, validation evidence, and anything still unverified.

For a large or cross-subsystem proposal, open a GitHub issue first so ownership and direction can be aligned before implementation.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security vulnerabilities through [`SECURITY.md`](SECURITY.md), never through a public issue.
