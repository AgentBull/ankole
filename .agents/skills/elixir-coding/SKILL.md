---
name: elixir
version: "0.4.0"
description: Ankole-specific Elixir, OTP, Ecto, Phoenix-shell, Rustler-boundary, and Torque guidance. Use when editing Elixir under app/control_plane, app/kernel, libs/feishu_openapi, or Elixir plugin code.
---

# Ankole Elixir Skill

This is a project-local working guide, not a general Elixir manual. Start from
the live code, local tests, and current `mix.exs` files. If a linked reference
or generic Elixir habit conflicts with Ankole's live shape, Ankole wins.

## When to Use This Skill

Use this skill when changing Elixir code, tests, docs, or examples in:

- `app/control_plane`
- `app/kernel`
- `libs/feishu_openapi`
- `plugins/*/lib` or `internals/plugins/*/lib`

Also load the more specific skill when the task is primarily about that surface:

- Phoenix routing/controllers/views/assets: use the `phoenix` skill too.
- Rustler/Rust NIF code: use the `rust-nif` skill too.
- Current library/API/CLI syntax: use Context7 per the repo instructions.

Do not treat this skill as permission to introduce unrelated ecosystem pieces.
Do not add LiveView, Tailwind, esbuild, Ash, Commanded, Broadway, Flow,
GenStage, Nerves, Tauri, Membrane, Zigler, Credo, Dialyzer, Sobelow, Archdo,
Mox, ExMachina, or StreamData unless the dependency already exists for the
touched package or the user explicitly asks.

## Current Project Shape

- `app/control_plane` is the main Phoenix 1.8 application. It is not API-only:
  Phoenix owns routing, auth/session state, the HTML shell, static asset
  serving, Ecto/Postgres, Oban, OpenAPI, plugins, and operator-facing endpoints.
  Vite owns the SPA entrypoints under `app/webapps`.
- `app/control_plane` uses Torque through the local `Ankole.JSON` adapter for
  Phoenix/Plug compatibility. Phoenix expects `encode_to_iodata!/1`; Torque's
  native API is not exactly that shape.
- `libs/feishu_openapi` is a thin Req + Mint WebSocket SDK. It owns Feishu/Lark
  request/response boundaries and decodes JSON explicitly with Torque.
- `app/kernel` is the Rustler-facing kernel package. Elixir owns the API shape;
  Rust owns native mechanics. Keep maps crossing the NIF boundary explicit and
  boring.
- Elixir runtime validation for this repo usually needs the kiex-managed stable
  1.20 environment:
  `source /Users/ding/.kiex/elixirs/elixir-1.20.1-29.env`.

## Local Defaults

- Do the requested change, not a broad cleanup.
- Inspect the existing module and tests before adding patterns.
- Prefer deletion and reuse over a new abstraction.
- Keep public APIs small. Promote a private helper to `def` only when another
  module genuinely owns that call.
- Comments and docs should explain Ankole-specific meaning, boundary choices,
  failure modes, or operator-visible behavior. Do not teach generic Elixir,
  Phoenix, CRUD, or pattern matching in code comments.
- Treat old BullX/BullX Agent code as reference material only. Ankole's current
  code and docs are the source of truth.

## Elixir Style

Use normal functional Elixir. The rules below are the default unless nearby code
has a clear local convention.

- Dispatch on data shape with pattern matching and multi-clause functions.
- Use `case` for one result, `with` for two or more `{:ok, _}` / `{:error, _}`
  steps.
- Use `if` only for simple boolean checks; do not build structural dispatch out
  of nested `if`.
- Return tagged tuples for expected failures. Reserve `raise` for programmer
  errors and startup/configuration failures.
- Reserve `try/rescue` for real boundaries around unsafe external code. To guard
  `GenServer.call/3` to an optional or external process, catch exits explicitly.
- Use `Enum`, `for`, `Map.new/2`, `Enum.into/2`, and `Enum.reduce_while/3`
  before hand-written recursion. Use recursion for tree/graph traversal or
  state machines where it is the clearest tool.
- Build strings as interpolation or IO data. Avoid repeated `<>` in loops.
- Use `%{struct | field: value}` for struct updates so unknown fields fail
  loudly. Use `Map.put/3` only when the key is dynamic.
- Put `@impl true` on every callback implementation. Use `@impl Behaviour` when
  a module implements multiple behaviours with overlapping callbacks.
- Put `@derive` before `defstruct` or `schema`.
- Prefer `alias` and qualified calls. Use full imports only for intended DSLs
  such as `Ecto.Query`, `Ecto.Changeset`, test helpers, and guard macros.
- Keep module order conventional: moduledoc, use/import/alias/require, module
  attributes, types, schema/struct, public functions, private helpers.

## JSON Rules

Ankole uses Torque, not Jason.

- Do not add `Jason` examples, dependencies, derives, or protocol assumptions.
- In `app/control_plane`, prefer `Ankole.JSON` at Phoenix/Plug/application
  boundaries.
- In `libs/feishu_openapi` and `app/kernel`, follow nearby code: usually
  `Torque.encode!/1`, `Torque.encode/1`, `Torque.decode!/1`, or
  `Torque.decode/1`.
- External JSON maps have string keys. Convert to atom-keyed structs/maps only
  at a deliberate boundary.
- Do not invent `Torque.Encoder` or Jason-style derive patterns. Convert structs
  to boundary maps explicitly when JSON shape matters.
- In `libs/feishu_openapi`, keep Req response decoding explicit. The SDK sets
  `decode_body: false`; decode response bodies before Feishu envelope or
  rate-limit handling when the body may be JSON.

## Phoenix and Web Boundaries

For Phoenix-specific changes, load the Phoenix skill and then apply these local
constraints:

- Keep Phoenix as the HTML shell plus backend control plane. Do not drift it
  toward API-only unless the user asks.
- Do not reintroduce LiveView, Tailwind, or esbuild. The frontend entrypoints
  live under `app/webapps` and are served through the Phoenix/Vite integration.
- Controllers should route, authenticate, translate parameters, and call domain
  contexts. Put durable behavior in context modules.
- Keep `AnkoleWeb.Assets` responsible for dev-server versus manifest asset URLs.
- Preserve the React Refresh preamble order when touching Vite tag injection.
- Use `open_api_spex` patterns already present when changing JSON API surfaces.

## Ecto and PostgreSQL

- Use changesets for external input. Use `change/2` only for trusted internal
  data.
- Prefer context functions over direct `Repo` calls from controllers or web
  boundary modules.
- Use `Repo.transact/1` or `Repo.transact/2` in this repo, matching nearby code.
  Do not introduce new `Repo.transaction/2` usage.
- Separate validations from constraints. Validations run before the DB write;
  constraints document and enforce DB truth.
- Use Postgres deliberately: constraints, indexes, JSONB, generated values,
  `on_conflict`, and locking are acceptable when they simplify the system.
- Avoid get-then-insert races. Prefer constraints and upserts where uniqueness
  matters.
- Do not preload inside loops. Batch with query preloads or `Repo.preload/2`.
- Keep migrations narrow and reversible when practical. Use
  `mix ecto.gen.migration` for new migrations.
- Treat migration metadata and generated DB artifacts as generated. Do not
  hand-edit generated metadata unless the user explicitly asks.

## OTP and Runtime Processes

- Supervise long-running processes. Avoid bare `spawn`/`spawn_link` for durable
  work.
- Use `Registry` + `DynamicSupervisor` for per-entity processes. Address a
  Registry-registered process through the same `{:via, Registry, ...}` tuple or
  local `via/1` helper it used at startup.
- Prefer `GenServer.call/3` with explicit timeouts when the caller needs a
  result. Use `cast` only for fire-and-forget work where loss is acceptable.
- Do not block GenServer callbacks on long HTTP, DB, or native work. Move slow
  work to a supervised task, Oban job, or a clearly isolated process.
- Use `handle_continue/2` for post-init work. If that work calls another
  process, confirm supervision ordering and set explicit timeouts.
- Keep large read-heavy state out of a single GenServer. Use ETS or the database
  when that is the simpler operational truth.
- Implement `format_status/1` for processes holding secrets, credentials,
  tokens, or sensitive runtime state.
- For actor-runtime work, keep Elixir as the owner of PG-backed durable state,
  admission, reconciliation, and operator-visible control. Rust/native code owns
  transport/protocol mechanics and should not grow direct Postgres ownership.

## Feishu/Lark SDK Notes

- `libs/feishu_openapi` should stay a thin SDK. Do not move Ankole domain policy
  into it.
- Keep request construction, auth refresh, event envelopes, card actions, and
  WebSocket protocol handling close to the existing module boundaries.
- Token managers and WebSocket clients are supervised OTP processes. Preserve
  their Registry/DynamicSupervisor addressing style.
- Decode JSON before interpreting Feishu envelopes, callback challenges, or
  rate-limit responses.
- Prefer tests around real request/body/protocol shape over mocks of internal
  modules.

## Testing

- Test through public APIs. Do not expose private functions only for tests.
- Use `async: true` unless the test mutates global state, named processes,
  Application env, Oban state, or shared DB assumptions.
- Use SQL sandbox patterns from `test/support` for database tests.
- Use `start_supervised!` for test-owned processes so ExUnit cleans them up.
- Use `assert_receive` / `refute_receive` with explicit timeouts instead of
  `Process.sleep/1`.
- Prefer focused regression tests for the touched behavior. Broaden coverage
  when changing shared runtime, schema, adapter, or web contracts.

## Validation Commands

Run commands from the package you changed, after sourcing the 1.20 toolchain
when needed.

For `app/control_plane`:

```bash
source /Users/ding/.kiex/elixirs/elixir-1.20.1-29.env
mix format
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

For `libs/feishu_openapi`:

```bash
source /Users/ding/.kiex/elixirs/elixir-1.20.1-29.env
mix format
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

For `app/kernel`, validate the Elixir package and any Rust/NIF path touched.
Load the `rust-nif` skill before changing Rustler code.

For small docs-only or skill-only edits, `git diff --check` is usually enough.
If the edit changes executable examples, run the relevant package tests.

## Optional Reference Files

Do not read all reference files by default. Open the smallest relevant file only
when the task needs it:

- `code-style.md`: formatter, module/function ordering, readability patterns.
- `architecture-reference.md`: larger context or supervision boundary changes.
- `ecto-reference.md`: Ecto query, migration, custom type, and Repo details.
- `otp-reference.md`: OTP callback signatures, child specs, Registry, ETS.
- `testing-reference.md`: ExUnit, SQL sandbox, process tests.
- `documentation.md`: ExDoc, `@doc`, `@spec`, doctests.
- `type-system.md`: compiler type warnings and specs.
- `debugging-profiling.md`: tracing, memory, message queues, profiling.
- `networking.md`: only for TCP/UDP socket work.

Low-probability topics such as event sourcing, Broadway/Flow/GenStage, desktop,
embedded, multimedia, and heavy static-analysis tools are intentionally absent
from this entrypoint. Reintroduce them only when the project actually uses them
or the user asks for them.
