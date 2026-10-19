# Webapps Agent Guidelines

This file applies to all files under `app/webapps/`. It supplements the root `AGENTS.md`.

## UX

Use the [Carbon Design System preview](https://preview.carbondesignsystem.com/) for interaction patterns: user goals, action sequence, information hierarchy, feedback, accessibility, and state transitions. Do not copy a pattern that changes Ankole product semantics. Do not add a Carbon dependency or Carbon components. Implement the interface with `@ankole/uikit` and Ankole color tokens. Alignment means a clear and predictable interaction.

## State

Use [Preact Signals](https://github.com/preactjs/signals) through `@preact/signals-react` for client state. Put reusable page, editor, and form logic in a `state/` model with `createModel`, `signal`, `computed`, and `batch`. Components use `useModel` and the current `useSignals` integration.

React state is only for transient state inside one component. Keep a value in one place. Use `computed` for derived state. Use an effect only to synchronize with an external system, and clean it up.

TanStack Query owns request state and the remote cache. Do not copy query data into a Signal to observe it. A Signal model may own an editable draft taken from query data. After a successful Console write, leave query refresh to `createConsoleMutationCache` in `console/query-client.ts`. Set `meta: { invalidates: false }` when the mutation changes no Console data. On a failure that needs fresh data, call `invalidateQueries` in `onError`. Setup and auth keep their own QueryClient.

A Console editor page seeds its draft with `useEditorDraft`. The `sourceKey` is stable and opaque, and it includes every selection dimension. The hook seeds each key once, so a refetch must leave operator edits in place. A model that holds pending request captures implements `resetSource`. Setup forms do not use this hook.

## Generated clients

`openapi/*.json` and `*/api/generated/` are generated. Change the owning control-plane declaration, regenerate the OpenAPI document, then run `bun run --filter @ankole/webapps openapi:generate`. Do not patch a generated file to change behavior.
