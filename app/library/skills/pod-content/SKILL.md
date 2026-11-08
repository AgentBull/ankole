---
name: pod-content
description: "Create and edit durable Pod pages, business Bases, files, and React applets. Use when the user wants a document saved in the workspace, a shared business table, a data-backed applet, or an independent report copy."
default_enabled: true
ankole-runtime: background_job
category: productivity
tags: [Pod, Pages, Base, Applets]
---

# Pod content

Chat records the work process. A Page keeps the result. Use the real Pod
contracts through `ankole-pod`; do not make a local file stand in for a saved
page or use browser storage as the authoritative base.

Run `ankole-pod --help` before the first operation. It lists the current
operations and parameter shapes. The CLI is available inside an active Agent turn.
Main routes this Skill to a Background Agent Job.

For deterministic recurring data tasks or polling more often than every 30 minutes,
create an Applet Action Job with `ankole-pod jobs.create` and manage its native
schedule with `ankole-pod jobs.schedules.put`. Pass business fields in `payload`; the Action
receives them in `ctx.signal.data` alongside planned and actual trigger times.
Use `ankole-pod jobs.webhooks.create` for Job-owned callbacks. These sources need no
Agent wakeup, `payload.task`, or chat delivery target. Emit a Signal only when
the result needs the Agent's judgment.

## Identity and access

The control plane checks your Agent Principal for every request. A personal
assistant acts with its human owner's business permissions. An AI colleague
uses its own business permissions, including when another Agent delegates work.
Human WorkAccess controls admission and ends the work when access is revoked;
it does not intersect the colleague's resource permissions with the human's.
An Applet Action uses its enabling Human for ordinary capabilities and its Page
owner for admin capabilities. It must hold its current execution attempt; review-required and
expired attempts cannot access Pod. If access is denied, ask for the required
sharing grant. Never use another identity or a hidden storage path.

A page is the unit of permissions and lifecycle. Every page type can have children. A Base holds its tables; tables and records are not pages.

Creating a child requires edit access to its parent page. The child
inherits that access; creation does not add a manage grant. Editing content,
title, or icon requires edit access. Edit access also permits a move when
the page and its descendants keep the same access permissions. A move that
changes those permissions requires Full access (`manage`) to the source;
every move requires edit access to the destination. Deleting, restoring, or
changing sharing still requires Full access. A rejected move leaves the source
in place. Keep its identity and ask for the needed access rather than claim
a replacement was moved.

Use `pages.update_sharing {id, upserts?, removes?}` or
`ankole-pod page update-sharing <page-id> '<JSON body>'` to add, update, or
remove individual grants without replacing other collaborators. A personal
assistant may grant the access implied by its owner's request to collaborate
with a named colleague. Use `contribute` (comment access) for document reviews and discussion, so the
colleague can answer follow-up comments on the page; use `view` for read-only
retrieval and `edit` for edits. Use `target_scope: "self"` for a single page. Keep unrelated grants. If the owner
cannot manage sharing, explain that a resource manager must grant access.

Read `pages.sharing {id}` for the current `sharing_version`, grants, and subjects.
Use `pages.set_sharing {id, sharing_version, inherit_permissions?, grants?}` or
`ankole-pod page set-sharing <page-id> '<JSON body>'` to replace sharing.
Each grant supplies one subject (`principal_uid`, `group_id`, or `source_page_id`
with `source_action`) and either `role` or exact `actions`, plus optional
`target_scope` and `condition`. A stale version requires a fresh read.

## Documents and files

Set a Page's `title` with `pages.create` or `pages.update`;
`pages.write` supplies its Markdown body. Follow the native Pod delivery
rules for Page authoring and the requested output format.
Every `pages.update` request that supplies `title` requires its last-read title as
`expected_title`, including `""` for an untitled Page. The server rejects a missing
or stale base with `title_conflict`. Read the current title and reconsider the
rename before retrying. Updates to other metadata do not require a title base.

1. Use `pages.search {query}` to find titles and document text, or read a known
   page ID. Search returns at most 30 matches. Use `pages.children {parent_id}`
   to browse a page's children; omit `parent_id` for roots. Pass `next_cursor`
   back as `cursor` until it is null. `pages.list` provides workspace lists.
2. Read its Markdown and revision before a change.
3. Use `pages.write` for a target body, `pages.append` for Markdown at the end,
   or `pages.patch` for exact `old_text` and `new_text` edits. Each operation
   requires that `base_revision`. A patch rejects missing or ambiguous text;
   `replace_all: true` permits all matches. The Worker uses the editor's codec.
   The control plane commits minimal structural and UTF-16 text changes.
4. If the write conflicts, read again and reconsider the change. Do not
   overwrite a newer revision or claim the old write succeeded.

Create child content where it belongs: pass the intended document's
`parent_id` to `pages.create`, then add a reference to it. Use
`<mention page="<document-page-id>" />` for a child document and an embed for
an interactive Base, File Page, or Applet. Do not create elsewhere and move it
merely to create a child. If inserting the reference fails, the child remains
in the page tree. Removing a reference from Markdown removes only the reference.
The page link form is `ankole:page/<page-id>`.

In document Markdown, put each inline embed on its own line. For an Applet,
use `<embed ref="<applet-page-id>" />`. For a Base view (including `grid`,
`kanban`, `gallery`, and `chart` views), use
`<embed ref="<base-page-id>" table="<table-id>" view="<view-id>" />` for a
shared saved view, or pass an inline JSON `ViewConfig` in `view` when a chart
or filtered view belongs exclusively to this report document. Use the saved page
and table IDs; read saved view IDs and field UUIDs from `base.schema`. Use
` ```mermaid ` for procedural flowcharts, sequences, state machines, and ER
diagrams (supported in both `doc` and `knowledge` pages), and ` ```infographic `
for structured narrative roadmaps, SWOT matrices, and comparisons in `doc`
pages (see the `visualization` Skill). A Markdown page link opens the referenced
page; an embed renders it inline.

Use `files.upload` for a file page, document image, or Base attachment.
Image uploads return an `ankole:asset/<digest>/<name>` address for the document.
Use `ankole-files get pages/<page-id>/<path> --pod` to read a page file into
your workspace. Uploads and publication commit through the page owner; do not
write arbitrary paths on the Pod drive.

Deleting a page moves its subtree into the trash. It can be restored before
purge begins. Deleting a chat does not delete the pages saved from it.

## Business data

A primary text field accepts at most 2 KiB of UTF-8 text. A link cell accepts
at most 2,000 IDs. Use a one-way child-to-parent link for a parent with more
than 2,000 children. The same API serves inline and physical tables.

Create the Base and typed fields before the applet. A new Base has
`Table 1` with a primary Name field; read it with `base.tables` before
creating another table. Give every table and field you create a short
`description` of at most 2 KiB that states what its values mean: the unit,
currency, tax inclusion, and source system when they apply, such as
`Order total in CNY, tax included, imported from the ERP`. People and later
Agents read these descriptions in `base.schema` to interpret the data, so
correct them with `base.configure_table` or `base.update_field` when that
meaning changes. Keep the IDs
returned by these operations and continue work on them. A rejected query does
not remove already saved pages or tables. Read the CLI parameter shapes and
correct that query instead of creating replacement content. Records use field
IDs as keys. Query a table and use the returned field versions when you change
records:

- An update sends only the changed data keys and their `expected_versions`.
  An unwritten field has no entry in that map.
- A delete sends the record's whole versions map.
- One batch contains at most 200 records and commits as a unit.
- A conflict requires a new read and a new decision. Different fields of the
  same record can be changed independently.

Contributors can create, update, and delete records and upload record
attachments. Editors can change fields, views, and documents and publish
Applets. Managers can delete tables and change sharing. A table referenced by
a link field must have that reference removed before deletion.

Formula fields are read-only and are evaluated by the server. Reference
same-record fields by name in formula source, such as `[Price] * [Quantity]`.
Do not implement a second formula evaluator in the applet. Linked records
must belong to the same Base.

For a report that must retain today's data, use `base.copy` with the
source table, target document, and optional filter. The copy has new IDs and
is independent. Links become text with their current titles in link order;
empty links become null. Formulas are checked against the copied field types.
Valid formulas recalculate from copied fields. A formula that cannot use the
new types becomes an ordinary field with its current result; array results
become JSON text. A live dashboard references the source Base instead.

## React applets

Use one CLI for initialization, build, publication, and source pull:

```text
ankole-pod applet init <directory>
ankole-pod applet build <directory>
ankole-pod applet publish <directory> '{"id":"<applet-page-id>","base_revision":0}'
ankole-pod applet pull <empty-directory> '{"id":"<applet-page-id>"}'
```

The generated entry exports `provider = defineApplet(App)` from
`@ankole/applet-sdk`. Keep source under `src/`. Build emits browser ESM,
`dist/index.html`, `dist/main.js`, shared chunks, and CSS. React, React DOM, `@ankole/uikit`,
and `@ankole/applet-sdk` are host dependencies. Keep all four out of
`package.json`; the host supplies them. Do not bundle another React
or add a global CSS reset. Keep custom CSS inside the Applet frame.
Import UIKit components from its root export. The build rejects UIKit component
subpaths and stylesheet imports; the host already loads those styles.
Import local images, fonts, and media from source, or reference them with CSS
`url()`. The build embeds imported resources in the published module graph. A plain
runtime path string does not include a resource in the build. Import a Worker
URL with `import workerURL from './calculation.worker.ts?url'`, then use
`new Worker(new URL(workerURL, import.meta.url), { type: 'module' })`.
The build compiles the Worker and resolves its URL from nested modules and
dynamic chunks. Applet init supplies the Worker URL import types.
Source pull requires edit access,
checks each file digest, and runs `bun install --ignore-scripts`.

### Pod UI and theme integration

An Applet fills the whole body of a Pod Page sheet (`var(--background)`). The
Page header above the iframe already shows the breadcrumbs ending in the Page
title and its source conversation, the Automation control, and the more-actions
menu; the iframe starts right below that header and spans the sheet's full width
and remaining height. The host pads the Applet's `html` with the Page's gutters:
`40px` on top and `48px` on each side (`28px` on top, `58px` and `24px` at the
sides on phones), widening the side gutters to center content in a `1440px`
column. That space scrolls with the content, so the Applet's scrollbar sits at
the sheet's edge:

- **Flush workspace layout**: Keep `body` and `.ankole-applet` flush with the
  host surface (`padding-inline: 0`, transparent or `var(--background)` canvas),
  and leave the host's padding on `html` in place. Size full-width rows with
  percentages or `width: auto`, not `100vw`, because the frame's viewport
  includes the gutters. Do not wrap the entire Applet in an outer
  card/border/shadow, or paint a standalone SaaS hero banner or full-bleed
  background wash. Align content to the gutters' left and right edges.
- **Page title**: The Page body has no title of its own, so an Applet may open
  with one `<h1>` that renders `usePod().title` in the Pod Page title style
  (`32px`, weight `600`, line height `42px`). The title follows renames, so never
  hardcode the Page name. Skip the heading when `usePod().embedded` is true,
  because the document already shows the title above the embed. Below the
  heading, or without it, open with compact workspace controls—a toolbar,
  search/filter bar, `Tabs`, KPI strip, or primary data view.
- **Embedded in documents**: A document gives an embedded Applet its content's
  height, up to one workspace viewport, so the Applet scrolls with the document.
  Let content set its own height. A layout sized from the viewport (`100vh`)
  keeps the whole viewport, and an open UIKit `Dialog`, `Sheet`, or `Drawer`
  expands the embed to the viewport while it is open.
- **Host-synced light and dark mode**: The Pod host sets
  `html[data-theme="light"]` or `html[data-theme="dark"]` and matching
  `color-scheme` on the iframe root before first paint, updating both live when
  the user toggles the external Pod theme. `usePod().theme` (from
  `@ankole/applet-sdk`) and `useTheme().resolvedTheme` (from `@ankole/uikit`)
  both return `'light' | 'dark'` reactively and re-render on theme switches.
  Never hardcode light or dark hex/RGB colors (`#fff`, `#f8fafc`, `#0f172a`,
  `#1e293b`), gradients, or `@media (prefers-color-scheme: dark)`—the user's Pod
  theme toggle controls `[data-theme="dark"]` independently of the OS media
  query. Rely on semantic CSS variables first, use `[data-theme="dark"]`
  selectors only when overriding custom CSS rules, and read
  `const { theme } = usePod()` (`theme === 'dark'`) when passing colors to
  `<canvas>`, SVG charts, or JavaScript visualizations.
- **Standard CSS + semantic tokens (no arbitrary Tailwind compilation)**:
  `ankole-pod applet build` bundles CSS with `Bun.build` and does **not** run a
  Tailwind compiler over Applet source. Arbitrary Tailwind classes written in
  JSX (`grid-cols-4`, `bg-slate-900`, `dark:bg-zinc-800`, `p-8`) will not
  generate styles unless they already exist in the host bundle. Write Applet
  layout (`display: grid`, `flex`, `gap`, responsive media queries) in
  `src/style.css` with Ankole's semantic tokens:
  - Surfaces: `var(--background)` (page paper), `var(--layer-01)` (raised
    band, table header, or code block), `var(--layer-02)`, `var(--layer-03)` /
    `var(--muted)`, `var(--layer-hover)` / `var(--accent)`,
    `var(--layer-current)` (selected nav/tab wash), `var(--field)` (input slot),
    `var(--control)` (outline button), `var(--selection)`.
  - Ink & typography: `var(--foreground)`, `var(--fg-secondary)` /
    `var(--muted-foreground)`, `var(--fg-tertiary)`, `var(--fg-placeholder)`,
    `var(--fg-disabled)`, `var(--font-family-sans)`, `var(--font-family-mono)`.
    Set `font-variant-numeric: tabular-nums` on counts, metrics, amounts, dates,
    and IDs. Keep section headings light and restrained (`14px` `600` inline
    headings or `16px` `400` section headings).
  - Borders & radius: `1px solid var(--border)` (`var(--border-strong)` for
    stronger dividers) and `var(--radius-control)` (`4px`). Keep controls at
    `4px` and cards/panels on paper square or `4px` without heavy drop shadows;
    `8px` ceramic glass belongs exclusively to UIKit overlays.
  - Brand & status roles: `var(--primary)` (`#e10059`) +
    `var(--primary-foreground)`—limit solid `<Button>` (`variant="default"`) to
    **at most one** primary call-to-action per view; use `variant="outline"` for
    standard actions, `variant="ghost"` for quiet toolbar/row actions, and
    `variant="destructive"` for irreversible deletes. Status tokens provide mark,
    text, and subtle container fills: `--info` / `--info-foreground` /
    `--info-subtle`, `--success` / `--success-foreground` / `--success-subtle`,
    `--warning` / `--warning-foreground` / `--warning-subtle`, and
    `--destructive` / `--destructive-foreground` / `--destructive-subtle` (plus
    perceptual ramps `--color-{gray,blue,cyan,teal,green,yellow,orange,red,magenta,purple}-{10..100}`
    for categorical charts: steps `60`–`70` in light mode, `30`–`50` in dark
    mode).
- **Use `@ankole/uikit` components and `@base-ui/react` composition**: Native
  HTML `<button>`, `<input>`, `<select>`, and `<table>` elements do not carry
  Pod control styling. Import components from root `@ankole/uikit`:
  - Actions & navigation: `Button` (`variant`: `'default' | 'outline' | 'ghost' | 'destructive' | 'link'`,
    `size`: `'default' | 'sm' | 'xs' | 'icon' | 'icon-sm' | 'icon-xs'`),
    `ButtonGroup`, `Tabs` / `TabsList` (`variant`: `'default' | 'object'`) /
    `TabsTrigger` / `TabsContent`, `Toggle`, `ToggleGroup`, `Pagination`.
  - Data & feedback: `Table` / `TableHeader` / `TableBody` / `TableRow` /
    `TableHead` / `TableCell`, `Card` (`size`: `'default' | 'sm'`) /
    `CardHeader` / `CardTitle` / `CardDescription` / `CardAction` /
    `CardContent` / `CardFooter`, `Badge` (`variant`:
    `'secondary' | 'info' | 'success' | 'warning' | 'destructive' | 'outline' | 'ghost'`,
    `size`: `'default' | 'sm'`—there is no `'default'` variant), `Alert` /
    `AlertTitle` / `AlertDescription`, `Empty` / `EmptyHeader` / `EmptyTitle` /
    `EmptyDescription` / `EmptyContent`, `Progress`, `Skeleton`, `Spinner`,
    `Separator`, `Avatar`, `Kbd`, `Toaster` + `toast`.
  - Visualization & charts: `AnkoleStatCard`, `AnkoleSparkline`, `AnkoleChart`
    (AntV G2 statistical charts), `AnkoleFinancialChart` (Lightweight Charts v5
    candlestick/OHLCV, volume/MACD/RSI sub-panes, markers, yield curves),
    `AnkoleGraph` (AntV G6 topology), and `AnkoleInfographic` (narrative
    infographics)—all dynamically code-split behind root `@ankole/uikit` exports
    (pair with `recordsToFinancialSeries`, `densifyTimeBuckets`, and
    `formatMetricValue` from `@ankole/applet-sdk`; see the `visualization`
    Skill for grammar and directional color rules: `var(--chart-up)` /
    `var(--chart-down)` default to international green-up/red-down, swapping to
    red-up/green-down via `marketConvention="cn"` only for Mainland China
    A-share equities).
  - Forms & filters: `Input`, `InputGroup`, `Textarea`, `Select` /
    `SelectTrigger` (`variant`: `'field' | 'ghost'`, `size`: `'default' | 'sm'`) /
    `SelectValue` / `SelectContent` / `SelectItem`, `Combobox`,
    `CreatableCombobox`, `Checkbox`, `Switch`, `RadioGroup` / `RadioGroupItem`,
    `Field` / `FieldLabel` / `FieldDescription` / `FieldError`, `Label`.
  - Overlays: `Dialog` / `DialogTrigger` / `DialogContent` / `DialogHeader` /
    `DialogTitle` / `DialogDescription` / `DialogFooter`, `Sheet`, `Drawer`,
    `Popover`, `DropdownMenu`, `Tooltip`. `@ankole/uikit` is built on
    `@base-ui/react` (not Radix): compose trigger buttons with
    `render={<Button variant="outline" />}` instead of `asChild`.

Use `useRecords(tableID, query)` for records and its `create`, `update`, and
`remove` methods for writes. Its TanStack Query result holds rows at
`result.data?.records`; `useAggregate` holds groups at `result.data?.groups`.
`usePod().actions` lists the selected user's permitted actions on the Applet
page. View access permits use of the Applet. Record writes require contribution
access to the target Base, and file content writes require edit access to
the target Page. Preserve form input when the target rejects a write.
Handle the query's loading and error states before rendering its data.
While a query is pending, show the shape of what is coming instead of plain
loading text. Draw `Skeleton` blocks shaped like the data the view will
render, such as table rows, cards, or a chart area, and size them in
`src/style.css`, because the Applet build does not compile Tailwind classes.
Center a `Spinner` when the content has no predictable shape, and put a small
`Spinner` beside the text of a field, a menu, or a busy button. The `Spinner`
is an inline element, so center it with a flex or grid container rather than
auto margins. Give the
loading container `role="status"` and an `aria-label` that names what is
loading.
Retain the record when editing begins. Call
`update(record.id, data, expectedVersions(record, data))`, importing
`expectedVersions` from `@ankole/applet-sdk`; call `remove(record.id, record.versions)`
for deletion. A later query refresh must not replace this edit snapshot. The SDK
updates the shared query cache and refreshes live data. Use `useAggregate` for
large table statistics. Use `usePod().pod` for the other Pod contracts.

Use `useChannel(room)` for temporary presence, cursors, or drag state. Its
`on(event, callback)` returns an unsubscribe function; register listeners in an
effect and return that function as the effect's cleanup.
Messages are not saved or replayed. Save durable results in Base. For
many simultaneous votes, append one record per vote and aggregate them;
do not repeatedly overwrite one counter.

The Applet runs as its current user in a same-origin iframe. Its document,
modules, and Workers use the tab's proven identity. The frame separates DOM,
CSS, and viewport layout; it shares the host's origin and trust boundary.
The host closes subscriptions and channels when a publication is replaced.
Keep DOM and styles in the frame and do not mutate the parent document.

Before publication, read the applet's current revision. Publication replaces
its complete source, distribution, and optional backend in one commit. A conflict requires a
new read. Open pages replace the old instance with the new revision.

## Applet backend routes

Use an optional `src/server/main.ts` for server validation, atomic record writes,
file parsing, cross-table summaries, or model calls. Ordinary record CRUD still
uses the frontend Base hooks. Import backend types with `import type`; the
server entry has no runtime module:

```ts
import type { Routes } from '@ankole/applet-sdk/server'

export default {
  'POST /orders/:id/summary': async ({ params, body }) => {
    const { text } = await AnkoleRuntime.ai.generateText({
      model: 'light', prompt: `Summarize order ${params.id}: ${body.note}`
    })
    return { summary: text }
  }
} satisfies Routes
```

`ankole-pod applet build` bundles this entry into `server/main.js` as one
ES module. NPM dependencies are bundled; Node built-ins use `node:` imports. Publish
validates the default export and returns its registered `routes` and `actions`.
The export can be a route table or `{ routes, actions }`; each named Action
declares `idempotent`, optional `concurrency` (`parallel`, `serial_fifo`, or
`serial_coalesce`), `concurrencyKey(ctx)`, `maxSlices`, and `handler(ctx)`. No server
source means no backend: rebuilding and publishing removes the old server.

Routes support GET, POST, PUT, PATCH, and DELETE. A handler receives `method`,
`path`, decoded `params`, flat `query` (repeated values are arrays), parsed JSON
`body`, `principal`, `applet: {pageId, revision}`, and tenant `timezone`.
Return JSON for 200, `undefined` for 204, or throw
`new AnkoleRuntime.HttpError(400, 'invalid_order', 'Check the order.')` for a 4xx
failure. Other exceptions produce a fixed browser error. Agent calls also receive
bounded diagnostic logs and handler exception details.

The function worker supplies Node built-ins, public `fetch`, an in-memory
`/tmp`, published environment values, and `AnkoleRuntime` capabilities:
`base.schema`, `base.query`, `base.aggregate`, `base.write`; `file.list`, `file.read`,
`file.write`; `metrics.query`, which runs a published Brain metric; `ai.generateText`; `mcp.call`; and `signals.call/emit/run`. Read their exact types in
`/repo/libs/applet-sdk/src/server.ts`. Put publication environment values in
`applet.env.json`, a flat string map of at most 64 KiB. Read each backend value
through `process.env.<KEY>`. Only editors can read
source, backend files, and environment values; viewers and contributors can
read published frontend assets.
Module top-level code must not call AnkoleRuntime; inspection rejects such calls.

Ordinary capabilities use the route caller or the personal Job's Human
authority. `AnkoleRuntime.admin` uses the Applet's current owner; service Jobs
have no ordinary caller and use that explicit owner surface. Viewing the Applet
does not grant access to its tables or files. GET handlers
cannot write. The runtime cannot create pages or change Base structure.
Function workers are reused by tenant, page, and publication revision. Keep
request-specific state inside the handler. Calls have no cross-call transaction; a later failure does not undo committed writes. Put an atomic batch
in one `base.write`, and include the field versions captured by the read.

Model generation uses the Agent that created the Applet (`Page.created_by`).
That Agent must be active; its model profiles, quota, and usage apply. Use a
model profile such as `light`, not a raw provider/model ID. The
runtime returns `{text, finishReason, usage}`; handle an empty or truncated result
when `finishReason` is `length`. Runtime errors preserve their status and code.

For an external operation, use
`await AnkoleRuntime.mcp.call(tool, args, {server, connection?, account?, skill?})`.
`server` identifies a Toolkit; provide `skill` to select an enabled Skill's
remote HTTP server. Use `admin.mcp.call` for the current Page owner. Follow the
Toolkit's generated input/output schema and present `HttpError.details.authorization_url`
when personal consent is required. Credentials remain outside Applet code.
A GET route may call only tools whose server lists them with
`readOnlyHint: true`; the host rejects any other tool with `read_only_route`
before contacting the server. Put a call to a tool without that annotation in
a POST route or an Action, even when it only reads data.

Action handlers receive business configuration in `ctx.job.config` and the
trigger envelope in `ctx.signal`. Keep progress in `ctx.state.get/set/delete`
or `ctx.state.scope(name)`. Each JSON value is limited to 64 KiB. Use
`ctx.remainingMs()` to budget work and return
`await ctx.continueSlice({delaySeconds, progress})` to continue the same Run;
the next slice uses the latest publication. Module variables and `/tmp` are not
durable state. A failure preserves its input, timestamps, logs and structured
error in the Run, so reconcile uncertain external writes before retrying.

`signals.emit({targetJobId,type,data})` queues a same-Page Job; omit `targetJobId`
to publish to configured Bindings. A route emits on `applet://<page-id>`; an
Action emits on `job://<job-id>`. An Agent wakeup
requires a Binding to its conversation. `signals.call({actionKey,data})` invokes
a same-Page Action synchronously in the remaining budget; it cannot continue a
slice. GET routes and nested calls remain read-only.

Frontend components can call `useAppletJobs()` for published Actions, Job
creation/configuration and Run history. `useJobSources(jobId)` manages that
Job's schedules and Webhooks; both hooks use the current Applet Page.
`useActionRun(runId)` follows accepted Run progress, results and errors.
Use the built-in Automation panel when a custom control is unnecessary.

For frontend reads, use the original declaration as the route:

```ts
const order = useRoute<{total: number}>('GET /orders/:id', {
  params: {id: orderId}, query: {currency: 'CNY'}, enabled: Boolean(orderId),
  staleTime: 30_000
})
const save = useRouteMutation('POST /orders/:id/summary', {
  onSuccess: () => runtime.queryClient.invalidateQueries({queryKey: runtime.routes.key()})
})
// The user action calls save.mutate({params: {id: orderId}, body: {note}}).
```

Import hooks and `usePod` from `@ankole/applet-sdk`; obtain `runtime` with
`usePod()`. Query and mutation options and result objects are TanStack Query's.
`useRoute` accepts only GET; `useRouteMutation` accepts only POST, PUT, PATCH, or DELETE.
For direct calls use `runtime.routes.call({method, path, query, body, signal})`.
Route queries include declaration, params, and query in their cache key and abort
on unmount. Access errors hide cached data; temporary failures retain it. Writes
have no optimistic update or automatic route-query refresh. Invalidate only the
queries affected by a successful write. The host binds calls to the loaded
publication revision. A stale revision reloads the applet; the rejected action is
not retried. Preserve important drafts in page-scoped storage and let the user
review them before submitting again.

For an Agent call use:

```text
ankole-pod applet call '{"id":"<applet-page-id>","method":"GET","path":"/orders/123","query":{"tag":["open","priority"]}}'
```

The result is `{status, body?, logs?}`. A handler error is a result with its actual
HTTP status and error envelope; do not treat a successful CLI exit as a successful
business action. Route writes use the active turn's write authorization and are
never retried after a disconnect. Read the saved result before deciding whether
a failed or interrupted action needs another submission.

## Verify and deliver

First identify which actions the Human authorized the Agent to perform and
when. An interaction reserved for a Human is not an Agent completion criterion.
Do not execute that interaction against the real Pod, including with scratch
records, temporary writes, rollback, or later cleanup. Do not change live
business data solely to make a smoke test pass. An Agent-authored write cannot
verify a Human-authored interaction.

For construction and writes that the Agent is already authorized to complete,
read back the saved page and published manifest. Trace each authorized action's
inputs through the handler's complete write payload to the full saved result.
Query the real table and check naming and description fields as well as derived
values. Aggregate changes or success messages do not replace this complete
result check. A successful build checks the distribution; it does not prove
that the applet works in the Pod host.

For a Human-reserved interaction, use only side-effect-free workspace checks
of the handler's complete payload, schema, and result handling. Include naming
and description fields; report this as a logic check. If the Human host
interaction has not occurred, deliver the saved result with that limit. Do not
continue the Job solely because that Human outcome is absent.

For rendered checks that the Agent is authorized to perform, use the existing
browser Skill. The Worker's browser does not automatically inherit the
requesting Human's Pod login. If no authorized Pod browser session is available,
state that the host interaction is unverified.
A standalone host or stub cannot prove the real SDK, Human permissions, or saved
writes. Do not create a replacement browser or session to bypass that boundary.
When the real host is unavailable, finish the available build and readback
checks, then deliver the saved result with that verification limit. Do not build
an alternate host as a substitute for the unavailable Human interaction.

Return a clickable link to the saved result in the final report, using
`[page title](ankole:page/<page-id>)`. State what was verified and any remaining
gap. A local source path or build directory is not the saved Pod result.
