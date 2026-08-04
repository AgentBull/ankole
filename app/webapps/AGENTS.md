# Webapps Agent Guidelines

This file applies to all files under `app/webapps/`. It supplements the root `AGENTS.md`. Follow both files.

## UX direction

- Use the [Carbon Design System preview](https://preview.carbondesignsystem.com/) as inspiration for UX, not as the source of Ankole's visual design or implementation. Align with its interaction patterns and design principles where they fit Ankole: make user goals, action sequences, information hierarchy, feedback, accessibility, and state transitions clear and consistent.
- Evaluate Carbon patterns as behavior and flow guidance. Apply the relevant interaction intent to actions, dialogs, disclosures, forms, filtering, navigation, notifications, and empty, loading, disabled, read-only, success, and error states. Do not copy a pattern when it changes Ankole's product semantics.
- Ankole does not use the Carbon component libraries. Do not add a Carbon dependency or copy Carbon components only to claim alignment. Continue to implement the UX with `@ankole/uikit` and the existing webapp architecture.
- Ankole's color palette intentionally differs from Carbon's default palette. Keep Ankole's own visual identity and tokens. Carbon alignment is measured by the clarity, consistency, and predictability of the user experience, not by visual or pixel-level similarity.

## Reuse and dependencies

- Before you add a local utility or a dependency, inspect `@agentbull/active-support` and the existing `common/` modules. Prefer an `@agentbull/active-support` utility when its behavior matches the requirement. Import it directly. Do not copy it or add a wrapper that only changes its name. The package provides Lodash-style utilities and re-exports `ts-pattern`.
- Use existing `@ankole/uikit` components and styles before you add a webapp-local equivalent.
- Use Bun for package installation, scripts, tests, and code generation, as the root guidelines require.

## State and data

- This project uses [Preact Signals](https://github.com/preactjs/signals) through `@preact/signals-react` as its client-state system. Put reusable page, editor, and form logic in a `state/` model. Use `createModel`, `signal`, `computed`, and `batch` in the model. Use `useModel` and the current `useSignals` integration in React components.
- React can own transient state that is local to one component. Do not store the same value in React state and a Signal.
- Use `computed` for derived state. Use an effect only to synchronize with an external system, and clean up the effect.
- Let TanStack Query own request state and the remote cache. Do not copy query data into a Signal only to make it observable. A Signal model can own an editable draft that starts from query data.

## UI and API boundaries

- Put cross-webapp providers and browser integration in `common/`. Keep product-specific pages and state in `console/` or `setup/`.
- Treat `openapi/*.json` and `console/api/generated/` as generated artifacts. Change the owning control-plane API declaration, regenerate the OpenAPI document, and then run `bun run --filter @ankole/webapps openapi:generate`. Do not patch generated artifacts to change behavior.

## Validation

- For webapp code changes, run `bun run --filter @ankole/webapps test` and `bun run --filter @ankole/webapps type-check`. Run `bun run --filter @ankole/webapps build` when the change affects generated API code, Vite integration, or production assets.
