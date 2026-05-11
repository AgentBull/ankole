# Rsbuild, Rstest, and Biome Frontend Tooling

The frontend test-runner portion of this plan was superseded by
`rfcs/plans/0017_Bun_Test_Migration.md`. The Rsbuild and Biome sections remain
as implementation history for the frontend toolchain migration.

## Scope

Replace the BullX frontend toolchain's Vite integration with Rsbuild, migrate frontend unit tests to Rstest, and add Biome as the JavaScript/TypeScript lint framework.

This affects the Phoenix control-plane asset boundary only:

- `package.json` and `bun.lock`
- `turbo.json`
- `rsbuild.config.ts`
- `rstest.config.ts`
- `biome.json`
- `webui/src/**`
- `config/*.exs`
- `lib/bullx_web/**`
- README asset-build documentation

No OTP supervision boundary changes. The Phoenix endpoint still owns the dev watcher process, and production still resolves digested static assets from a manifest under `priv/static/assets`.

## Cleanup Plan

### Delete

- Remove `assets/vite.config.mjs`.
- Remove the `BullXWeb.Vite` and `BullXWeb.Vite.Manifest` modules.
- Remove Vite-only imports, scripts, dependency entries, environment names, config keys, and documentation text.
- Remove the Bun test-runner import from frontend unit tests.
- Remove the old `assets/js` source-tree location after moving the files to `webui/src`.

### Reuse

- Keep the existing `mix assets.build` and `mix assets.deploy` aliases; only their underlying JS build command changes through `package.json`.
- Keep Phoenix endpoint watchers for the frontend dev server process; `bun dev` starts Phoenix, and Phoenix starts the Rsbuild watcher.
- Keep the existing root layout asset component call pattern, replacing only the module that resolves assets.
- Keep the existing TOML client-locale import behavior by porting the loader into an Rsbuild plugin.
- Keep the existing React/Inertia source shape and TypeScript path aliases, with the root moved to `webui/src`.

### Changed Code Paths

- Phoenix development asset loading changes from a Vite dev-server module path to Rsbuild's emitted dev assets.
- Phoenix production asset loading changes from a Vite manifest chunk map to Rsbuild's `entries.*.initial` manifest shape.
- Frontend unit tests change from `bun:test` APIs to `@rstest/core`.
- Frontend linting becomes an explicit `biome check` script with a root `biome.json`.
- The frontend application source root changes from `assets/js` to `webui/src`.

### Invariants

- `webui/src/app.tsx` is the React/Inertia entry.
- SPA pages live under `webui/src/apps/`.
- Production assets remain served from `/assets`.
- `mix assets.deploy` still runs compilation, the JS asset build, and `phx.digest`.
- `bun precommit` is the developer precommit entrypoint.
- Process-local state and OTP supervision remain unchanged.

### Verification

- `bun install`
- `bun run build`
- `bun dev` plus a request for `/.rsbuild/manifest.json`
- `bun run test`
- `bun run lint`
- `bun precommit`
