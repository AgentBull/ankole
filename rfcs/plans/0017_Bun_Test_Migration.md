# Bun Test Migration

## Scope

Migrate frontend unit tests from Rstest to Bun's built-in test runner and keep the test environment ready for Testing Library.

This affects the frontend test boundary only:

- `package.json` and `bun.lock`
- `bunfig.toml`
- `webui/src/**/*.test.{ts,tsx,js,jsx}`
- `webui/src/test/**`
- `rstest.config.ts`

No OTP supervision boundary, Phoenix request path, or Rsbuild build/dev behavior changes.

## Cleanup Plan

### Delete

- Remove `rstest.config.ts`.
- Remove `@rstest/adapter-rsbuild` and `@rstest/core`.
- Remove Rstest imports from frontend unit tests.

### Reuse

- Use Bun's built-in `bun test` runner.
- Keep the existing `bun run test` and `bun precommit` entrypoints.
- Keep Happy DOM as the browser-like DOM implementation for frontend tests.

### Changed Code Paths

- Frontend tests import test APIs from `bun:test`.
- `bun run test` executes Bun tests under `webui/src`.
- Bun preloads Happy DOM and Testing Library matcher setup through `bunfig.toml`.

### Invariants

- Rsbuild remains the frontend build/dev tool.
- Phoenix still owns server-side asset serving and dev watcher integration.
- Frontend tests stay scoped to `webui/src`.
- `bun precommit` remains the developer precommit entrypoint.

### Verification

- `bun install`
- `bun run test`
- `bun run lint:js`
- `bun precommit`
