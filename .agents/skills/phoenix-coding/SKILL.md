---
name: phoenix
version: "0.4.0"
description: Ankole-specific Phoenix control-plane guidance. Use when editing app/control_plane web routes, controllers, plugs, OpenAPI, session handling, Phoenix/Vite shell integration, or Phoenix tests.
---

# Ankole Phoenix Skill

This is a project-local Phoenix guide. It is intentionally not a full Phoenix
manual. Read the live code first, then use this file to keep changes inside the
control-plane shape Ankole has already chosen.

## Current Shape

- The Phoenix app lives in `app/control_plane`.
- Phoenix owns browser routing, sessions, CSRF, setup/auth gates, JSON APIs,
  OpenAPI specs, static serving, and the HTML shell.
- React/Vite owns the application screens under `app/webapps`.
- `libs/uikit` owns reusable frontend UI. Do not move UI concerns into Phoenix.
- Phoenix is not API-only, and it is not LiveView-driven. It renders thin HTML
  shell responses for SPA entrypoints.
- The endpoint uses Bandit, custom `AnkoleWeb.SessionCookieStore`, and
  `Ankole.JSON` as the configured Phoenix JSON library.
- The current named SPA entries are `auth`, `console`, and `setup`.

## Use With Other Skills

- Load the `elixir` skill for Ecto, OTP, Oban, context, or general Elixir code.
- Load Context7 when changing Phoenix/OpenApiSpex/Plug/Vite API usage or CLI
  syntax.
- Do not use this skill as a reason to add LiveView, Phoenix Tailwind/esbuild
  assets, Absinthe, generated auth scaffolding, Presence, Channels, or generic
  deployment machinery unless the user explicitly asks or the dependency already
  exists in the touched package.

## Local Rules

- Do the requested change. Do not broaden it into a Phoenix cleanup.
- Preserve `app/control_plane` as the single Phoenix home.
- Keep the web layer thin: controllers/plugs authenticate, validate, translate
  params, and call Ankole contexts.
- Do not call `Repo` directly from controllers or plugs. Use context modules.
- Use verified routes `~p` for internal browser redirects and paths.
- Keep session and CSRF behavior in Phoenix. Do not push auth/session gates into
  Vite or static files.
- Keep API response envelopes consistent with nearby controllers.
- Prefer small explicit plugs over hidden controller-side conditionals when a
  route group owns the concern.
- Prefer explicit controller actions over Phoenix generators. Generators are
  allowed for migrations/schemas when they match the existing package shape, but
  do not accept generated LiveView/Tailwind/template scaffolding by default.

## Router and Pipelines

The router currently has four important surfaces:

- `:browser`: HTML shell routes with session, flash, CSRF, and secure headers.
- `:session_api`: JSON-shaped setup/auth endpoints that still use browser
  session and CSRF protection.
- `:openapi`: OpenAPI rendering under `/api/openapi.json`.
- `:console_api`: stateless console REST API authenticated by bearer token.

Rules:

- Keep setup/auth mutation endpoints on `:session_api` unless there is a clear
  reason to make them stateless.
- Keep console REST endpoints on `:console_api` and document them through
  OpenApiSpex.
- Do not move SPA route guards into React. `SpaController` decides whether the
  operator sees setup, auth, or console.
- Keep catch-all SPA routes narrow (`/console/*path`, `/setup/*path`,
  `/auth/*path`) and route them to the correct shell action.
- Avoid route namespace duplication. A scoped alias should own the module prefix.

## SPA Shell and Vite Assets

`AnkoleWeb.SpaController` returns the server-owned HTML shell. `AnkoleWeb.Assets`
resolves the Vite entry tags.

- Preserve the Phoenix-owned shell: `<!doctype>`, `<html lang>`, CSRF meta tag,
  title, Vite tags, and `#ankole-app`.
- Keep the shell as simple iodata or an equally thin template. Do not rebuild a
  server-rendered UI layer.
- `AnkoleWeb.Assets` switches between dev-server URLs and the production Vite
  manifest. Keep this as the single Phoenix asset resolver.
- In dev, React Refresh preamble must be emitted before `@vite/client` and the
  entry module. Otherwise backend-served shells can hit the Vite React
  "can't detect preamble" failure.
- Do not add `phoenix_vite` as a dependency just to copy its integration shape;
  use it only as reference if needed.
- Do not reintroduce Phoenix esbuild or Phoenix Tailwind watchers. Vite is
  started through the `app/webapps` watcher.
- If Vite behavior looks stale, check for an old process holding port `3035`
  before rewriting integration code.

## Controllers and Plugs

- Controllers should be direct and boring: authorize, parse params, call a
  context, return `html/2`, `json/2`, redirect, or an error envelope.
- Use `with` for chained context calls and a private `error/2` or `error/5`
  helper for controller-local translation.
- Keep plug modules small. Implement `@behaviour Plug`, `init/1`, and `call/2`
  with `@impl`.
- If a plug rejects a request, set the status, return the existing JSON/HTML
  shape, and `halt/1`.
- Do not put durable domain behavior in `AnkoleWeb.*`.
- For browser redirects after login/setup, call `delete_csrf_token/0` or reuse
  the local session helper when rotating session state.

## JSON and OpenAPI

- Phoenix JSON goes through `Ankole.JSON`, not Jason.
- External JSON request bodies and generated API clients use string-keyed maps at
  the boundary. Convert deliberately before calling domain code.
- OpenAPI endpoints should use `OpenApiSpex.ControllerSpecs` and the schema
  modules under `AnkoleWeb.Schemas`.
- Keep `OpenApiSpex.Plug.CastAndValidate` close to the controller that owns the
  API action and use `AnkoleWeb.OpenApiValidationErrorRenderer` for validation
  errors.
- When changing console API routes or response schemas, update the OpenAPI spec
  and regenerate/check the webapp client if the frontend consumes it.

## Sessions, Auth, and Security

- Browser session state lives in the custom cookie store. Preserve
  `same_site`, `http_only`, `secure`, and `max_age` semantics.
- Setup/auth JSON endpoints are not public stateless APIs just because they
  return JSON. They still rely on browser session and CSRF.
- Console REST API requests use bearer access tokens through
  `AnkoleWeb.Plugs.RequireConsoleAccessToken`.
- Validate return URLs with `AnkoleWeb.Session.safe_return_to/1`; do not trust
  arbitrary `return_to` values.
- Never use `String.to_atom/1` on request data.
- Never use `raw/1` or unescaped iodata with untrusted user content.
- Keep production secrets in runtime configuration and fail loudly when required
  env vars are missing.

## I18n and HTML

- Server-rendered shell text should go through the local Ankole I18n helpers,
  not Gettext.
- Preserve `<html lang>` behavior from the active Ankole locale.
- Keep Phoenix text minimal; application copy belongs mostly in the webapps.

## Ecto and Oban From Phoenix

- Controllers should call contexts such as `Ankole.AppConfigure`,
  `Ankole.AdminAuth`, or other domain modules. They should not assemble queries.
- For DB changes, use the `elixir` skill's Ecto rules and existing context
  patterns (`Repo.transact`, constraints, upserts, migrations).
- Oban workers belong in domain code, not controllers. Route actions enqueue or
  call contexts; they do not perform long blocking work inline.

## Configuration

- `config/config.exs` owns compile-time defaults and should keep
  `config :phoenix, :json_library, Ankole.JSON`.
- `dev.exs` starts Vite through the watcher and configures
  `AnkoleWeb.Assets` with `http://127.0.0.1:3035`.
- `test.exs` points `AnkoleWeb.Assets` at `http://assets.test`.
- `runtime.exs` runs in every environment. Keep global runtime settings
  deliberate and narrow; guard prod-only Repo, endpoint, and secret config with
  `if config_env() == :prod`.
- If `mix phx.server` fails early, check the local Postgres database and the
  kiex Elixir environment before assuming Phoenix code is broken.

## Testing

- Use existing `ConnCase` and `DataCase` support.
- Test route behavior through controllers/plugs rather than private helpers.
- For session/API boundaries, assert status, response envelope, redirects,
  session changes, and CSRF-sensitive behavior where relevant.
- Use the SQL sandbox patterns already in `test/support`.
- Keep tests focused on the changed route, plug, controller, or shell behavior.
- For generated OpenAPI/client changes, also validate the relevant webapp
  type-check or client generation path.

## Validation Commands

From `app/control_plane`:

```bash
source /Users/ding/.kiex/elixirs/elixir-1.20.1-29.env
mix format
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

From the repo root when frontend/OpenAPI/Vite integration is touched:

```bash
bun run --filter @ankole/webapps openapi:generate
bun run --filter @ankole/webapps type-check
bun run --filter @ankole/webapps build
```

Use the smallest validation set that proves the changed surface. For docs-only
or skill-only edits, `git diff --check` is enough.

## Optional Reference Files

Do not read these by default. Open the smallest relevant file only when needed:

- `reference.md`: Plug.Conn helpers, router DSL, session config, component attrs.
- `examples.md`: larger controller/plug/context/security examples.

Most LiveView, Tailwind, GraphQL, Presence, Channels, and deployment examples
from generic Phoenix guides are intentionally absent here. Reintroduce them only
after the project actually adopts that surface or the user asks for it.
