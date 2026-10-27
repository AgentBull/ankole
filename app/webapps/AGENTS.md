# Webapps Agent Guidelines

These guidelines apply to all files under `app/webapps/` and supplement the root `AGENTS.md`.

## UX

Follow the [Carbon Design System preview](https://preview.carbondesignsystem.com/) for interaction design—user goals, action flows, information hierarchy, feedback, accessibility, and state transitions—so interfaces remain clear and predictable. Do not copy patterns that alter Ankole's product semantics, and do not add Carbon packages or components; build every screen with `@ankole/uikit` and Ankole color tokens.

## State

Manage shared client state with [Preact Signals](https://github.com/preactjs/signals) via `@preact/signals-react`. Place reusable page, editor, and form logic in a `state/` model built from `createModel`, `signal`, `computed`, and `batch`, and consume those models in components with `useModel` and `useSignals`.

Reserve local React state (`useState`) for transient UI state confined to a single component. Keep every piece of state in a single source of truth, derive secondary values with `computed`, and use effects only when synchronizing with an external system (always cleaning them up on unmount).

TanStack Query owns server request state and the remote cache. Never copy query data into a Signal merely to observe it, though a Signal model may hold an editable local draft seeded from query data. After a Console mutation succeeds, let `createConsoleMutationCache` in `console/query-client.ts` handle cache invalidation automatically; set `meta: { invalidates: false }` only when a mutation changes no Console-visible state, and call `invalidateQueries` inside `onError` when a failed write requires refetching server state. Setup and authentication apps each maintain their own `QueryClient`.

Console editor pages initialize local drafts through `useEditorDraft`. Keep `sourceKey` stable, opaque, and inclusive of every selection dimension. Because the hook seeds each `sourceKey` only once, background refetches leave in-progress operator edits intact. Models that capture pending request payloads must implement `resetSource`. Do not use `useEditorDraft` in setup forms.

## Generated clients

Files under `openapi/*.json` and `*/api/generated/` are machine-generated. To change an API contract, update the owning declaration in the control plane, regenerate the OpenAPI spec, and run `bun run --filter @ankole/webapps openapi:generate`. Never hand-edit generated client files.
