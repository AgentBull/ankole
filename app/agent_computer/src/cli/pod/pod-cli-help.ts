export const POD_FIRST_USE_GUIDANCE = [
  'ankole-pod writes pure JSON to stdout; run `ankole-pod --help` for full operations and schemas.',
  '- Read/search pages & directory tree: `ankole-pod pages.tree` (`\'{"scope":"all","depth":3}\'`), `ankole-pod pages.search \'{"query":"..."}\'`, `ankole-pod pages.read \'{"id":"<node-id>","markdown_path":"page.md"}\'`',
  '- Office Pages (.xlsx/.xlsm/.docx/.docm/.pptx in Pod): `ankole-pod office inspect|render|commands|apply|to-document ...` (use `OfficeCLI` only for scratch files in `/workspace`, never to overwrite active Pod Office Pages)',
  '- Comments on pages & files: `ankole-pod comments list|show|reply|resolve <node-id> ...`',
  '- Base tables: `ankole-pod base.tables|base.schema|base.query|base.write \'{"id":"..."}\'`',
  '- If a write or sharing change is forbidden, draft an Action Card via `propose_action_card` for human confirmation.'
].join('\n')

export const POD_CLI_HELP = `ankole-pod — durable pages and data in your Pod

Run inside an active Ankole turn. Each operation uses the Agent's
Principal permissions. If access is denied, ask a member to share the page
or add your Agent to the space.

  ankole-pod chat attachment get <conversation-id> <message-id> <position> --to <worker-path>
  ankole-pod comments list <page-id|--page id> [--status open|resolved|all|unread] [--cursor <token>] [--limit <n>]
  ankole-pod comments show <page-id|--page id> <comment-id|--comment id>
  ankole-pod comments reply <page-id|--page id> <root-comment-id|--root id> <body|--body text>
  ankole-pod comments resolve <page-id|--page id> <comment-id|--comment id> --version <n> [--reopen]
  ankole-pod office inspect <page-id> ['<JSON>'] [--sheet <name>] [--range <A1:Z50>] [--story <story>] [--from <n>] [--to <n>]
  ankole-pod office render <page-id> (--page <n> | --slide <n>) [--scale <n>] --to <worker-path>
  ankole-pod office commands <page-id> [<query>]
  ankole-pod office apply [<page-id>] '<JSON>' | --input <JSON file>
  ankole-pod office to-document <page-id> [--parent <parent-id>]
  ankole-pod pages.search [<query>] [--domain all|pages|brain] [--type <types>] [--scope all|private|space|shared|conversation] [--ancestor <id>] [--title-only] [--sort best|updated_desc|updated_asc|created_desc|created_asc] [--limit <n>]
  ankole-pod <operation> '<JSON parameters>'
  ankole-pod <operation> --input <JSON file>
  ankole-pod applet init <directory>
  ankole-pod applet build <directory>
  ankole-pod applet pull <directory> '<{"id":"page-id"}>'
  ankole-pod applet call '<{"id":"page-id","method":"GET","path":"/orders","query":{}}>'
  ankole-pod applet publish <directory> '<{"id":"page-id","base_revision":0}>'
  ankole-pod page set-sharing <page-id> '<{"sharing_version":"...","inherit_permissions":false,"grants":[]}>'

Read operations:
  pages.list       {scope?: space|private|shared|recent|favorites|trash, query?}
  pages.children   {parent_id?, scope?: space|private, cursor?, limit?} — returns pages and next_cursor
  pages.tree       {parent_id?, scope?: all|space|private, depth?, limit?} — returns the nested directory tree (ankole-pod pages.tree defaults to scope="all", depth=3)
  pages.search     {query, domain?: all|pages|brain, types?, scope?, ancestor_id?, created_by?, updated_after?, title_only?, sort?, limit?, required_action?, exclude_subtree_of?} — full-text search across Pages and Brain (defaults to domain="all"); returns pages, ancestors, and matches (match_fields, snippet.segments, primary_target)
  pages.read       {id} — returns Markdown and the current page revision
  pages.sharing    {id}
  comments.list    {id, status?: open|resolved|all|unread, cursor?, limit?} — lists document or file comment threads
  comments.show    {id, comment_id} — returns a comment thread with quote, anchor, and replies
  files.manifest   {id}
  files.download   {id, path, local_path, sha256?}
  office.inspect   {id, sheet_id?, sheet?, range?, story?, from_block?, to_block?, from_slide?, to_slide?, slide_id?} — reads logical structure and text of a Spreadsheet, Word, or Presentation Page
  office.render    {id, page | slide, scale?} --to <worker-path> — renders a 1-based Word page or Presentation slide to PNG at <worker-path>
  office.commands  {id, query?} — lists engine commands and parameter schemas for a Word or Presentation Page
  base.tables  {id: base_page_id}
  base.schema  {id: table_id}
  base.query   {id, search?, filter?, sort?, page_size?, page_token?, ids?, group?}
  base.aggregate {id, filter?, group_by?, metrics, order_by?, top_n?, omit_empty?}
  jobs.schedules.list {page_id, job_id}
  jobs.schedules.runs {page_id, job_id, id}
  jobs.webhooks.list {page_id, job_id}
  jobs.list {page_id}
  jobs.actions {page_id} — discover published Action keys
  jobs.runs {page_id, job_id} — list the latest 100 Runs
  jobs.get_run {page_id, run_id} — read authorized Run status and progress
  bindings.list {config_ref}

Write operations:
  pages.update_sharing {id, upserts?, removes?} — incrementally change sharing; use target_scope: "self" for one page
  pages.set_sharing {id, sharing_version, inherit_permissions?, grants?} — requires manage access
  pages.create     {type: file|doc|knowledge|base|applet, title, parent_id?, private_owner_uid?, markdown?, icon?}
    Omitting both parent_id and private_owner_uid creates at the shared Space (Workspace) root. Pass parent_id
    to file under an editable parent Page in Space or Private, or pass private_owner_uid (principal_uid from
    pages.children — the human owner's UID for a personal assistant, never the Agent UID) for the Private root.
    Knowledge pages require parent_id and markdown, including YAML frontmatter when present. pages.create
    ignores icon for a Knowledge page; set it afterward with pages.update.
  pages.update     {id, title?, expected_title?, icon?} — expected_title is required whenever title is supplied
    In pages.create and pages.update, icon is exactly one emoji, such as "📊"; send null to remove it.
    Any other text fails with invalid_icon, so put a label such as "Demo data" in the title or content.
  pages.move       {id, parent_id?, private_owner_uid?} — omit both to move to Space root, or pass parent_id or private_owner_uid
  pages.delete     {id} — moves the subtree into the trash
  pages.restore    {id}
  pages.write      {id, base_revision, markdown} — stale writes are rejected
  pages.append     {id, base_revision, markdown}
  pages.patch      {id, base_revision, edits:[{old_text,new_text,replace_all?}]}
  comments.reply   {id, root_id, body} — replies to an existing root comment thread (requires comment access)
  comments.resolve {id, comment_id, version, resolved?: boolean} — resolves or reopens a root thread
  files.upload     {id, local_path, role: file|asset|attachment, base_object_id?}
    For role=file, pass the current files.manifest entry's object_id as
    base_object_id; omit it only when the file is empty. Stale replacements fail.
  office.apply     {id, expected_revision?, commands?: [{command, params?}], ops?: [op]} — edits an Office Page through its live operation log without resetting human editors
  office.to_document {id, parent_id?} — converts a Word Page into a native Document Page and returns the new page and conversion report
  base.create_table {id: base_page_id, name, description?}
  base.configure_table {id: table_id, description?, unique_field_ids?, emit_changes?}
  base.delete_table {id: table_id} — requires manage access
  base.create_field {id: table_id, name, type, description?, config?, is_primary?}
  base.update_field {id: field_id, version, is_primary?, clear_invalid?, ...changes}
  base.delete_field {id: field_id, version}
  base.create_view  {id: table_id, name, type, config?}
  base.update_view  {id: view_id, version, ...changes}
  base.delete_view  {id: view_id, version}
  base.write    {id: table_id, creates?:[{data}], updates?:[{id,data,expected_versions}], deletes?:[{id,expected_versions}], upserts?:[{data}]}
  base.copy     {id: table_id, parent_id: report_page_id, filter?}
  jobs.schedules.put {page_id, job_id, name, schedule, timezone?, payload?, id?, idempotency_key?}
  jobs.schedules.pause|resume|delete {page_id, job_id, id}
  jobs.schedules.run {page_id, job_id, id, idempotency_key}
  jobs.webhooks.create {page_id, job_id, label, expires_at, mode?: standing|one_shot, event_format?: raw|cloudevents}
  jobs.webhooks.update {page_id, job_id, id, label?, expires_at?}
  jobs.webhooks.pause|resume|cancel|delete {page_id, job_id, id}
  jobs.create {page_id, action_key, authorization_kind: human|service, label?, config?}
  jobs.configure {page_id, id, label?, config?}
  jobs.delete {page_id, id}
  bindings.put {id?, config_ref, automation_job_id?, agent_uid?, target?, filters?, watched_field_ids?, enabled?}
  applets.transfer_owner {id: page_id, owner_uid} — current owner or Pod administrator
  applets.call      {id, method: GET|POST|PUT|PATCH|DELETE, path, query?, body?}
    Returns {status, body?, logs?}, including handler errors. Never replay a
    write after a disconnect: first read its saved result.

Base parameter shapes:
  Read base.schema before writing; data keys and field_id values are the
  returned field UUIDs, not field names. Reuse the saved page and table IDs.
  Tables and fields carry a description (at most 2 KiB) that states what the
  values mean: unit, currency, tax inclusion, or source system.
  filter: {conjunction:"and"|"or", conditions:[{field_id, operator, value?}]}
    operator: is|not_is|in|contains|is_empty|is_not_empty|gt|gte|lt|lte|text_contains
  sort: [{field_id, direction:"asc"|"desc"}]
  group_by: [{field_id, bucket?:"day"|"week"|"month"|"quarter"|"year"}]
  metrics: [{operation:"count"|"sum"|"avg"|"min"|"max"|"count_distinct", field_id?, alias}]
    field_id is required except for row count. For example:
    {"id":"TABLE_ID","metrics":[{"operation":"sum","field_id":"FIELD_ID","alias":"total"}]}
    order_by: [{metric_alias?, group_index?, direction:"asc"|"desc"}];
    top_n: {limit, include_other?, target_group_index?}; omit_empty?: boolean.
    Results contain groups:[{values,value_json?,other?,metrics:{total:...},metrics_text?}],
    data_version, and data_versions:{TABLE_ID:version} for every table read.
  base.aggregate follows link fields in the same Base with path:[LINK_FIELD_ID,...]
    (at most 3 hops); field_id then names a field of the table the path reaches.
    group_by: [{field_id, path, bucket?}] needs single-value links only.
    filter conditions: [{field_id, path, operator, value?}] match when a linked
    record matches; [{operator:"exists"|"not_exists", path, filter?}] test for
    linked records, where filter holds conditions on the linked table.
    metrics: [{operation:"count"|"sum"|"avg"|"min"|"max", field_id?, path, filter?, alias}]
    total linked records per row before grouping, so a row with three linked
    records still counts its own fields once. Use these paths instead of joining
    tables yourself.
  query results: {records:[{id,data,versions,...}],complete,page_token,data_version}
    When complete is false, pass page_token to the next query with the same
    search, filter, sort, ids, and group. Aggregate calculates over all matching rows.
    For chart drill-down, pass group: [{field_id, value?, value_json?, bucket?,
    cumulative_from_json?, other_exclude_values_json?}] on base.query / base.records.
  Upserts require a configured scalar business key and every key value. Unchanged
  normalized values do not advance versions or emit changes.
  data: {"FIELD_ID": value}; expected_versions: {"FIELD_ID": last_read_version}
    An unwritten field has no expected_versions entry. Creates need no versions.
  field type: text|number|select|datetime|checkbox|user|attachment|auto_number|
    link|formula|created_at|updated_at|created_by|updated_by
    formula config: {source:"[Price] * [Quantity]"}; formulas are read-only.
    select config: {multiple?:boolean,options:[{id,name,color?}]}; records store option IDs.
    link config: {table_id,multiple?:boolean,bidirectional?:boolean}.
    datetime values use ISO 8601; user values are arrays of Principal UIDs.
  view type: grid|kanban|gallery|chart
    ChartViewSpec (type: "chart"): config: {filter?, chart: {chart_type,
    query: {group_by?, metrics, top_n?, omit_empty?}, encoding?, display?}}.
    Chart display sorting uses display.sort_mode: metric_desc|metric_asc|key_asc|key_desc|option_order.

Document & Knowledge visualizations:
  :doc pages embed saved or inline Base chart views via <embed ref="<base-page-id>" table="<table-id>" view="<view-id-or-json>" />,
  external webpage cards/previews via <embed href="https://..." view="card"? title? description? image? height? />,
  structured AntV infographics via <infographic> or \`\`\`infographic (:doc only), and Mermaid diagrams via <mermaid> or \`\`\`mermaid.
  :knowledge pages support plain \`\`\`mermaid / <mermaid> (without attributes); \`\`\`infographic in :knowledge renders as a plain code block and <infographic> XML is rejected.
  New or modified Mermaid and Infographic blocks are syntax-checked before pages.create, pages.append, pages.write, and pages.patch.

Page access:
  view reads content and records. On documents and files, contribute adds comment
  access; use it for document reviews and discussion that continue on the page.
  On a Base, contribute writes records and uploads record attachments; edit
  changes schemas and metadata.
  Pass parent_id to pages.create to create a child. Creating a child requires
  edit on its parent Page. A child inherits permissions; creating it does not grant manage.
  The first write to an empty file requires contribute on its parent. Replacing
  file content, renaming, or moving an existing file requires edit. Deleting a
  file requires edit; deleting a document, Knowledge Page, Base, or Applet requires
  manage. Restoring trash and changing sharing require manage.
  A move that changes the subtree's access requires manage on the source, plus
  permission to create a child in the destination. Editing document or Applet
  content, titles, and icons requires edit.

Always read before updating. A record patch carries versions for the fields
it changes; record deletion carries the whole versions map. A conflict means
read again and reconsider the change. Do not retry an old write blindly.
Use files.download with the page ID and manifest-relative path to read a page file.

Applets export provider = defineApplet(App) from src/main.tsx, use @ankole/uikit
components and @ankole/applet-sdk hooks, and save business data in Base.
Applet init accepts a new directory or an existing empty directory.
The Worker includes the actual SDK at /repo/libs/applet-sdk/src/index.tsx
and its query, aggregate, and record types at /repo/libs/applet-sdk/src/types.ts.
Frontend build emits browser ESM chunks and dist/index.html (Bun.build without Tailwind compilation:
write custom layout CSS in src/style.css using Ankole semantic CSS variables such as
var(--background), var(--layer-01), var(--foreground), var(--fg-secondary), var(--border),
and var(--radius-control) rather than arbitrary Tailwind utility classes or hardcoded hex colors).
Import components (Button, Badge, Card, Table, DataGrid, ApprovalCard, Tabs, Input, NumberInput, Slider,
DatePicker, DateRangePicker, FileDropzone, Stepper, PrincipalBadge, Textarea, Select, Combobox,
Checkbox, Switch, Field, Label, Dialog, Sheet, Drawer, Popover, DropdownMenu, Tooltip,
Alert, Empty, Skeleton, Spinner, Toaster, toast, useTheme, AnkoleChart, AnkoleFinancialChart,
AnkoleYieldCurveChart, AnkoleInfographic, AnkoleStatCard, AnkoleSparkline, Graph) from the root "@ankole/uikit"
export (@base-ui/react: pass render={<Button variant="outline" />} on triggers instead of asChild;
Badge variants are secondary|info|success|warning|destructive|outline|ghost; use at most one
default primary Button per view and outline/ghost for other actions).
While data loads, render Skeleton blocks shaped like the coming view (size them in src/style.css),
a centered Spinner when the shape is unknown, or a small Spinner beside a field's text, inside
role="status" with an aria-label; never render plain loading text.
The Pod Page header above the iframe shows the Page title, source conversation, and Automation,
and the host pads the Applet's html with the Page's gutters (40px top, 48px sides, a centered
1440px column): keep body and the Applet flush, size full-width rows with percentages instead of
100vw, and do not wrap the app in an outer card/shadow/gradient wash. To show a title, render
usePod().title, which follows renames, in one opening h1 at 32px weight 600; never hardcode the
Page name. A document gives an embedded Applet its content's height up to one viewport, so use
vh heights only for an Applet that should fill the viewport. The host syncs
html[data-theme="light|dark"] and color-scheme on the iframe and updates usePod().theme
('light' | 'dark') reactively on theme switches; never use @media (prefers-color-scheme: dark).
Import runtime APIs (including usePod, usePrincipals, usePrincipal, and pod.navigateToPage/openChat)
and visualization data helpers (recordsToFinancialSeries, densifyTimeBuckets,
formatMetricValue) from "@ankole/applet-sdk".
Do not import their runtime subpaths or UIKit styles; the Pod host supplies styles.
SDK type subpaths remain available through "import type".
Worker entries use src/**/*.worker.ts or .worker.js and build to matching
relative dist/**/*.worker.js paths. Import a Worker URL with
import workerURL from './calculation.worker.ts?url', then start it with
new Worker(new URL(workerURL, import.meta.url), {type:'module'}).
The imported URL works from nested modules and dynamic chunks.
Optional src/server/main.ts
exports a default route table typed with import type { Routes } from
'@ankole/applet-sdk/server'. Build bundles it into server/main.js as ESM with external node:* builtins.
The runtime provides Node builtins, temporary /tmp files, fetch, process.env merged from
Site -> Pod -> applet.env.json defaults -> Applet environment overrides (applet.env.json accepts
flat string defaults or {default?, required?, secret?, description?} declarations), and
AnkoleRuntime base, file, ai ({generateText, generateImage, generateSpeech, transcribe, ocr, decide}),
web ({search, fetch}), mcp, signals and HttpError. GET handlers cannot write or call
ai.generateImage or ai.generateSpeech. Use file.read(path, {sha256})
to read the listed version or receive a manifest_changed conflict.
Use notifications.post for native room alerts. Use approvals.request/list/get/decide for
Human decisions; only the assigned reviewer can decide in a browser mutation route.
Use brain.listFacts for Company Brain knowledge and brain.listTakes/writeTake/calibration for
source-scoped research predictions.
Backend exports may contain {routes, actions}. Each Action declares idempotent,
concurrency (parallel|serial_fifo|serial_coalesce), concurrencyKey(ctx), maxSlices,
and handler(ctx). Jobs hold configuration and durable state; code owns policy.
ctx.state.get/set/delete and ctx.state.scope(name) persist cursors; remainingMs()
and continueSlice({delaySeconds,progress}) continue the same Run with latest code.
AnkoleRuntime capabilities use the caller or personal Job owner; team Jobs use
AnkoleRuntime.admin, which executes as the Applet's current owner. GET and nested
calls are read-only. mcp.call(tool,args,{server,connection?,account?,skill?})
uses a Toolkit (type per platform with import type { Inputs, Outputs } from '@ankole/applet-sdk/toolkits/<toolkit>'),
or an enabled remote HTTP Skill when skill is supplied.
admin.mcp uses the current Page owner; HttpError.details preserves consent links
and recovery metadata. signals.emit({targetJobId,type,data}) accepts a same-Page Job;
omit targetJobId to publish to Bindings and check delivered for a delivery receipt.
Routes use applet://<page-id> and Actions use job://<job-id>. An Agent wakeup needs
a Binding to its conversation. signals.call({actionKey,data}) runs synchronously
within the remaining budget.
Applet pull restores source and package files, then runs bun install --ignore-scripts.
useAppletJobs() manages published Actions, Jobs and Run history;
useJobSources(jobId) manages that Job's schedules and Webhooks. Use the built-in
Automation panel when custom controls are unnecessary.
Use useActionRun(runId) in the frontend to follow accepted Run progress, results,
and errors; it refreshes after reconnecting. Use useRoute/useRouteMutation for
routes; route writes do not refresh queries
unless the applet explicitly invalidates them.
Applet view access permits use. Record and file writes require access to the target resource.
Publish checks base_revision and
atomically replaces source, distribution and optional backend. Removing the backend
source and rebuilding removes the previously published backend. A copied table is independent
of its source; a page reference continues to read the referenced page.`
