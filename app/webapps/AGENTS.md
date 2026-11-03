# Webapps Agent Guidelines

These guidelines apply to all files under `app/webapps/` and supplement the root `AGENTS.md`.

## UX

Ankole's design language balances enterprise productivity systems (Carbon, SAP Fiori, Salesforce Lightning, Palantir Blueprint) against personal-experience systems (Notion, Fluent 2, shadcn/ui, Apple Liquid Glass), leaning slightly toward the personal side. From the enterprise side, an interface keeps tolerance for error, information density, throughput, explicit state, and accessibility. From the personal side, it keeps cognitive load low, keeps chrome quiet, and lets content lead. Interaction design draws on Linear and the Pleisto q prototype: fast paths, a keyboard route for every action, and calm navigation. The Pod sidebar follows the structure of a Notion sidebar so that users can rely on a familiar model. The visual language is Ankole's own, so do not copy the signature look of another product, and do not copy any pattern that alters Ankole's product semantics.

Build every screen with `@ankole/uikit` and its tokens, and do not add packages or components from another design system. Style with Tailwind CSS first: write utility classes on the element, and add a rule to a stylesheet only when a utility cannot express it, such as markup that another library renders. A style that several components share becomes a `@utility` in `libs/uikit/src/styles.css`, not a class repeated in app stylesheets. Each pattern has one owner: change a control in `@ankole/uikit` (for example, the `nav-row` states) or document typography in `@ankole/block-editor` so that every surface follows, instead of restyling it on one page.

## Browser support

Chrome 126 is the minimum supported Chrome version. Use native browser features
available at that floor, and detect newer capabilities before depending on them.
The Pod browser suite accepts `POD_BROWSER_EXECUTABLE_PATH` for testing a pinned
browser, including the Chrome 126 installation used by the block editor's
compatibility suite.

## State

Manage shared client state with [Preact Signals](https://github.com/preactjs/signals) via `@preact/signals-react`. Place reusable page, editor, and form logic in a `state/` model built from `createModel`, `signal`, `computed`, and `batch`, and consume those models in components with `useModel` and `useSignals`.

Reserve local React state (`useState`) for transient UI state confined to a single component. Keep every piece of state in a single source of truth, derive secondary values with `computed`, and use effects only when synchronizing with an external system (always cleaning them up on unmount).

TanStack Query owns server requests, pagination, list membership, and remote response snapshots.

In Pod, `state/page-metadata.ts` owns the shared Page title and icon projection in TanStack DB; request functions feed successful responses into it, and confirmed writes and content events update it by Page ID. Read those display fields through `usePageMetadata` or `usePagesMetadata`, keeping permissions and document drafts with their existing owners.

Never copy query data into a Signal merely to observe it, though a Signal model may hold an editable local draft seeded from query data.

After a Console mutation succeeds, let `createConsoleMutationCache` in `console/query-client.ts` handle cache invalidation automatically; set `meta: { invalidates: false }` only when a mutation changes no Console-visible state, and call `invalidateQueries` inside `onError` when a failed write requires refetching server state. Setup and authentication apps each maintain their own `QueryClient`.

Console editor pages initialize local drafts through `useEditorDraft`. Keep `sourceKey` stable, opaque, and inclusive of every selection dimension. Because the hook seeds each `sourceKey` only once, background refetches leave in-progress operator edits intact. Models that capture pending request payloads must implement `resetSource`. Do not use `useEditorDraft` in setup forms.

## Generated clients

Files under `openapi/*.json` and `*/api/generated/` are machine-generated. To change an API contract, update the owning declaration in the control plane, regenerate the OpenAPI spec, and run `bun run --filter @ankole/webapps openapi:generate`. Never hand-edit generated client files.
