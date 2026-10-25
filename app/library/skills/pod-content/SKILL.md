---
name: pod-content
description: "Create and edit durable Pod pages, business databases, files, and React applets. Use when the user wants a document saved in the workspace, a shared business table, a data-backed applet, or an independent report copy."
default_enabled: true
ankole-runtime: background_job
category: productivity
tags: [Pod, Pages, Database, Applets]
---

# Pod content

Chat records the work process. A Page keeps the result. Use the real Pod
contracts through `ankole-pod`; do not make a local file stand in for a saved
page or use browser storage as the authoritative database.

Run `ankole-pod --help` before the first operation. It lists the current
operations and parameter shapes. The CLI is available inside an active Agent turn or an authorized
Automation Job attempt. Main routes this Skill to a Background Agent Job.

## Identity and access

The control plane checks your Agent Principal for every request. Work driven
by a Human uses the intersection of that Human's permissions and your Agent's
permissions. A service Automation Job uses its Agent's own permissions. An
Automation Job must hold its current execution attempt; review-required and
expired attempts cannot access Pod. If access is denied, ask for the required
sharing grant. Never use another identity or a hidden storage path.

A page is the unit of permissions and lifecycle. Every page type can have children. A Database holds its tables; tables and records are not pages.

Creating a child requires edit access to its parent page. The child
inherits that access; creation does not add a manage grant. Editing content,
title, or icon requires edit access. Edit access also permits a move when
the page and its descendants keep the same access permissions. A move that
changes those permissions requires Full access (`manage`) to the source;
every move requires edit access to the destination. Deleting, restoring, or
changing sharing still requires Full access. A rejected move leaves the source
in place. Keep its identity and ask for the needed access rather than claim
a replacement was moved.

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

1. List the pages you can see or read the requested page.
2. Read its Markdown and revision before a change.
3. Use `pages.write` for a target body, `pages.append` for Markdown at the end,
   or `pages.patch` for exact `old_text` and `new_text` edits. Each operation
   requires that `base_revision`. A patch rejects missing or ambiguous text;
   `replace_all: true` permits all matches. The Worker uses the editor's codec.
   The control plane commits minimal structural and UTF-16 text changes.
4. If the write conflicts, read again and reconsider the change. Do not
   overwrite a newer revision or claim the old write succeeded.

Create inline content where it belongs: pass the intended document's
`parent_id` to `pages.create`, then add its embed. Do not create elsewhere and
move it merely to create a child. If inserting the embed fails, the child remains
in the page tree. Removing an embed from Markdown removes only the reference.
The page link form is `ankole:page/<page-id>`.

In document Markdown, put each inline embed on its own line. For an Applet,
use `<embed ref="<applet-page-id>" />`. For a Database view, use
`<embed ref="<database-page-id>" table="<table-id>" view="<view-id>" />`.
Use the saved page and table IDs; read the view ID from `database.schema`.
A Markdown page link opens the referenced page; the embed renders it inline.

Use `files.upload` for a file page, document image, or Database attachment.
Image uploads return an `ankole:asset/<digest>/<name>` address for the document.
Use `ankole-files get pages/<page-id>/<path> --pod` to read a page file into
your workspace. Uploads and publication commit through the page owner; do not
write arbitrary paths on the Pod drive.

Deleting a page moves its subtree into the trash. It can be restored before
purge begins. Deleting a chat does not delete the pages saved from it.

## Business data

Create the Database and typed fields before the applet. A new Database has
`Table 1` with a primary Name field; read it with `database.tables` before
creating another table. Keep the IDs
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
must belong to the same Database.

For a report that must retain today's data, use `database.copy` with the
source table, target document, and optional filter. The copy has new IDs and
is independent. Formulas refer to the copied fields and recalculate when those
fields change. Links become fixed multiple-select options with the original
record IDs and current titles. A live dashboard references the source Database
instead.

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
or add a global CSS reset. Use the host components and theme. For standard action
buttons, use `import { Button } from '@ankole/uikit'`. Native `button` elements
do not include the host's control styles. Keep custom CSS inside the Applet frame.
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

Use `useRecords(tableID, query)` for records and its `create`, `update`, and
`remove` methods for writes. Its TanStack Query result holds rows at
`result.data?.records`; `useAggregate` holds groups at `result.data?.groups`.
`usePod().actions` lists the selected user's permitted actions on the Applet
page. View access permits use of the Applet. Record writes require contribution
access to the target Database, and file content writes require edit access to
the target Page. Preserve form input when the target rejects a write.
Handle the query's loading and error states before rendering its data.
Retain the record when editing begins. Call
`update(record.id, data, expectedVersions(record, data))`, importing
`expectedVersions` from `@ankole/applet-sdk`; call `remove(record.id, record.versions)`
for deletion. A later query refresh must not replace this edit snapshot. The SDK
updates the shared query cache and refreshes live data. Use `useAggregate` for
large table statistics. Use `usePod().pod` for the other Pod contracts.

Use `useChannel(room)` for temporary presence, cursors, or drag state. Its
`on(event, callback)` returns an unsubscribe function; register listeners in an
effect and return that function as the effect's cleanup.
Messages are not saved or replayed. Save durable results in Database. For
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
uses the frontend Database hooks. Import backend types with `import type`; the
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
validates the default route table and returns its registered `routes`. No server
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
`db.schema`, `db.query`, `db.aggregate`, `db.write`; `file.list`, `file.read`,
`file.write`; and `ai.generateText`. Read their exact types in
`/repo/libs/applet-sdk/src/server.ts`. Put publication environment values in
`applet.env.json`, a flat string map of at most 64 KiB. Read each backend value
through `process.env.<KEY>`. Only editors can read
source, backend files, and environment values; viewers and contributors can
read published frontend assets.
Module top-level code must not call AnkoleRuntime; inspection rejects such calls.

Each capability uses the current caller's permissions, not the author's.
Viewing the applet does not grant access to its tables or files. GET handlers
cannot write. The runtime cannot create pages or change Database structure.
Function workers are reused by tenant, page, and publication revision. Keep
request-specific state inside the handler. Calls have no cross-call transaction; a later failure does not undo committed writes. Put an atomic batch
in one `db.write`, and include the field versions captured by the read.

Model generation needs tenant `pod.applet.ai_agent_uid` configured to an active
Agent. Use a model profile such as `light`, not a raw provider/model ID. The
runtime returns `{text, finishReason, usage}`; handle an empty or truncated result
when `finishReason` is `length`. Runtime errors preserve their status and code.

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
