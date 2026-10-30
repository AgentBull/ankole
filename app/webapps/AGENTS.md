# Webapps Agent Guidelines

These guidelines apply to all files under `app/webapps/` and supplement the root `AGENTS.md`.

## UX

Ankole's design language balances enterprise productivity systems (Carbon, SAP Fiori, Salesforce Lightning, Palantir Blueprint) against personal-experience systems (Notion, Fluent 2, shadcn/ui, Apple Liquid Glass), leaning slightly toward the personal side. From the enterprise side, an interface keeps tolerance for error, information density, throughput, explicit state, and accessibility. From the personal side, it keeps cognitive load low, keeps chrome quiet, and lets content lead. Interaction design draws on Linear and the Pleisto q prototype: fast paths, a keyboard route for every action, and calm navigation. The Pod sidebar follows the structure of a Notion sidebar so that users can rely on a familiar model. The visual language is Ankole's own, so do not copy the signature look of another product, and do not copy any pattern that alters Ankole's product semantics.

Every surface is one of three materials. The ground is the app frame that holds the header and the navigation; paper holds content and anything that lasts; alumina ceramic holds everything transient, such as menus, popovers, dialogs, sheets, tooltips, and toasts. Interaction states are ink and never change the material: hover is a light ink wash, the current place is a denser wash, focus is a 2px ink ring, and selection is the glaze colour. Colour follows intent. Berry marks only the brand and the primary action; status uses its conventional colour together with a distinct icon and text; links are ink with an underline.

Controls share one grammar: heights of 32, 28, and 24px, a 4px radius (3px for small parts), slots that hold content and objects that are pressed or chosen, and a bottom edge one step darker than the sides. A disabled button keeps its outline and drops its fill, so it never reads as an empty slot. Ceramic has an 8px radius (4px for tooltips), and panels on the paper stay square.

Each role has one form, wherever it appears, so the person reads a role from its look:

| Role | Form |
| --- | --- |
| Control in a header band or toolbar | ghost button or ghost select |
| Field in a form | `Input` (`default`) |
| Field inside ceramic, such as a find bar or menu search | `Input variant="overlay"` |
| Text renamed where it stands, such as a title or a list row | `Input variant="inline"` |
| Object in content on paper, such as tool output or a run card | `content-object` (one hairline, 4px) |
| Code, and table cells, in documents and chat alike | `code-surface`, `code-toolbar`, `code-text`, `code-inline`, `content-cell` |
| Anything that floats over content, such as a picker, a preview, or a jump button | `ceramic` |
| Inline mark, such as a page pill or a badge | 3px radius on an ink wash |

Text is at least 12px. Only marks that are not read as words, such as avatar initials and shortcut hints, go below that.

Every sheet of paper on the ground is the same object, painted by the `paper-sheet` utility: a 16px radius, the paper fill, and the shared `--paper-shadow` edge. The shell's inset is one such sheet. A side panel such as Page chat or Comments is a second sheet beside the page rather than a column inside it: content that lays out several sheets marks each one `data-sheet` and paints it with `paper-sheet`, and the inset then gives up its own sheet and keeps only its clearance, so two sheets sit twice that clearance apart. A sheet's header band is the `sheet-header` utility (44px, controls 12px from the edge), and its first words, a `sheet-title` or a path link, start 18px in; the page header ends in a hairline that separates its chrome from the scrolling content, while a side panel's header is only that panel's title and carries no line. When a band runs short, its action labels give way before its title (`@container` on the band, a max-width container variant of `sr-only` on the label). Chrome speaks in two voices: text says where the person is, and monochrome icons with labels say what they can do. Page icons, emoji, and colour belong to the content, not to a header path, and a select in a header band or a toolbar, such as the chat composer's, is a ghost select (text and a chevron), because a field slot there would read as an input.

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
