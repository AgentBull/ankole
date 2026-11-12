import { helpRequested } from '../primitives'
import { isRecord } from '@agentbull/active-support'
import { mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { isBuiltin } from 'node:module'
import type { BunPlugin } from 'bun'
import { POD_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import { errorMessage, nodeErrorCode } from '../../common/errors'
import { emitFirstUseGuidance, installStdoutEpipeGuard, markHelpSeen } from '../cli-guidance'

const POD_FIRST_USE_GUIDANCE = [
  'ankole-pod writes pure JSON to stdout; run `ankole-pod --help` for full operations and schemas.',
  '- Read/search pages: `ankole-pod pages.search \'{"query":"..."}\'` (or `ankole-pod pages.search "<query>" [--title-only] [--type doc|knowledge|base|applet|file]`), `ankole-pod pages.read \'{"id":"<node-id>","markdown_path":"page.md"}\'`',
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
    Knowledge pages require parent_id and markdown, including YAML frontmatter when present. pages.create
    ignores icon for a Knowledge page; set it afterward with pages.update.
  pages.update     {id, title?, expected_title?, icon?} — expected_title is required whenever title is supplied
    In pages.create and pages.update, icon is exactly one emoji, such as "📊"; send null to remove it.
    Any other text fails with invalid_icon, so put a label such as "Demo data" in the title or content.
  pages.move       {id, parent_id?, private_owner_uid?}
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

export async function initializeApplet(directory: string) {
  try {
    await mkdir(directory, { recursive: false })
  } catch (error) {
    if (nodeErrorCode(error) !== 'EEXIST') throw error
    if ((await readdir(directory)).length > 0) throw new Error(`Applet directory must be empty: ${directory}`)
  }
  await mkdir(join(directory, 'src'))
  await writeFile(
    join(directory, 'src/main.tsx'),
    `import { Badge, Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@ankole/uikit'\nimport { defineApplet, usePod } from '@ankole/applet-sdk'\n\nfunction App() {\n  const { theme } = usePod()\n  return (\n    <main className="applet-shell" data-applet-theme={theme}>\n      <div className="applet-toolbar">\n        <Badge variant="secondary">{theme === 'dark' ? '深色模式' : '浅色模式'}</Badge>\n      </div>\n      <Empty>\n        <EmptyHeader>\n          <EmptyTitle>工作区就绪</EmptyTitle>\n          <EmptyDescription>页边距由 Page 提供，页面标题显示在顶栏。请从工具栏、筛选栏或主数据视图开始，直接贴边排布。</EmptyDescription>\n        </EmptyHeader>\n      </Empty>\n    </main>\n  )\n}\n\nexport const provider = defineApplet(App)\n`,
    { flag: 'wx' }
  )
  await writeFile(
    join(directory, 'src/style.css'),
    `.ankole-applet {\n  color: var(--foreground);\n  font-family: var(--font-family-sans);\n}\n\n.applet-shell {\n  display: flex;\n  flex-direction: column;\n  gap: 16px;\n  padding-block: 4px 24px;\n}\n\n.applet-toolbar {\n  display: flex;\n  align-items: center;\n  gap: 8px;\n}\n`,
    { flag: 'wx' }
  )
  await writeFile(
    join(directory, 'src/applet.d.ts'),
    `declare module '*.worker.ts?url' { const url: string; export default url }\ndeclare module '*.worker.js?url' { const url: string; export default url }\n`,
    { flag: 'wx' }
  )
  return { directory, entry: 'src/main.tsx' }
}

// The Pod host registers these exact module names. Package exports outside
// this list can be valid in the monorepo without being available in an applet.
const appletHostModules = [
  'react',
  'react/jsx-runtime',
  'react/jsx-dev-runtime',
  'react-dom',
  'react-dom/client',
  '@ankole/uikit',
  '@ankole/applet-sdk'
]

function appletBuildError(stage: string, error: unknown) {
  const errors = error instanceof AggregateError ? error.errors : Array.isArray(error) ? error : [error]
  return new Error(`${stage}:\n${errors.map(String).join('\n')}`)
}

const appletAssetPattern =
  /\.(?:png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp3|mp4|webm|ogg|wav|pdf|wasm|bin)(?:[?#].*)?$/i

const appletAssets: BunPlugin = {
  name: 'applet-assets',
  setup(build) {
    build.onResolve({ filter: appletAssetPattern }, args => {
      if (args.importer.endsWith('.css') || /^(?:[a-z][\w+.-]*:|\/\/|#)/i.test(args.path)) return
      const [, filename, suffix] = args.path.match(/^([^?#]+)(.*)$/)!
      return { path: `${Bun.resolveSync(filename!, args.resolveDir)}${suffix}.url.js`, namespace: 'applet-asset-url' }
    })
    build.onLoad({ filter: /.*/, namespace: 'applet-asset-url' }, args => {
      const [, filename, suffix] = args.path.slice(0, -7).match(/^([^?#]+)(.*)$/)!
      return {
        contents: `import path from ${JSON.stringify(`applet-asset:${filename}`)}; export default new URL(path + ${JSON.stringify(suffix)}, import.meta.url).href;`,
        loader: 'js'
      }
    })
    build.onResolve({ filter: /^applet-asset:/ }, args => ({
      path: args.path.slice('applet-asset:'.length),
      namespace: 'applet-asset-file'
    }))
    build.onLoad({ filter: /.*/, namespace: 'applet-asset-file' }, async args => ({
      contents: await readFile(args.path),
      loader: 'file'
    }))
  }
}

export async function buildApplet(directory: string) {
  directory = await realpath(directory)
  const packageFile = Bun.file(join(directory, 'package.json'))
  if (await packageFile.exists()) {
    const manifest = await packageFile.json()
    for (const group of ['dependencies', 'devDependencies', 'peerDependencies']) {
      for (const name of ['@ankole/applet-sdk', '@ankole/uikit']) {
        if (manifest[group]?.[name] !== undefined) {
          throw new Error(`Remove ${name} from package.json ${group}; the Pod host supplies this package`)
        }
      }
    }
  }
  const outdir = join(directory, 'dist')
  const serverDirectory = join(directory, 'server')
  await rm(serverDirectory, { recursive: true, force: true })
  await rm(outdir, { recursive: true, force: true })
  await mkdir(outdir, { recursive: true })
  const sourceDirectory = await realpath(join(directory, 'src'))
  const workers = (await readdir(sourceDirectory, { recursive: true }))
    .filter(name => /\.worker\.(?:ts|js)$/.test(name))
    .map(name => join(sourceDirectory, name))
  if (workers.length) {
    const built = await Bun.build({
      entrypoints: workers,
      root: sourceDirectory,
      naming: { entry: '[dir]/[name].js', asset: 'assets/[name]-[hash].[ext]' },
      outdir,
      target: 'browser',
      format: 'esm',
      splitting: false,
      plugins: [appletAssets],
      define: { 'process.env.NODE_ENV': '"production"' }
    }).catch(async error => {
      await rm(outdir, { recursive: true, force: true })
      throw appletBuildError('Applet worker build failed', error)
    })
    if (!built.success) {
      await rm(outdir, { recursive: true, force: true })
      throw appletBuildError('Applet worker build failed', built.logs)
    }
  }
  const result = await Bun.build({
    entrypoints: ['ankole-applet-entry'],
    plugins: [
      appletAssets,
      {
        name: 'applet-entry',
        setup(build) {
          build.onResolve({ filter: /^ankole-applet-entry$/ }, () => ({ path: 'app', namespace: 'applet' }))
          build.onResolve({ filter: /\.worker\.(?:ts|js)\?url$/ }, async args => {
            const source = await realpath(resolve(args.resolveDir, args.path.slice(0, -4)))
            if (!workers.includes(source)) {
              throw new Error('Worker URL imports must refer to a Worker source under src/')
            }
            return {
              path: join(outdir, source.slice(sourceDirectory.length + 1).replace(/\.ts$/, '.js')),
              namespace: 'applet-worker-url'
            }
          })
          build.onLoad({ filter: /.*/, namespace: 'applet-worker-url' }, args => ({
            // The URL asset imports the original bundle so its resource URLs keep their base.
            contents: `import ${JSON.stringify(`../${args.path.slice(outdir.length + 1)}`)};`,
            loader: 'file'
          }))
          build.onResolve({ filter: /^(?:react|react-dom|@ankole\/(?:uikit|applet-sdk))\// }, args => {
            if (appletHostModules.includes(args.path)) return
            if (
              /^(?:react|react-dom)\//.test(args.path) &&
              args.importer.replaceAll('\\', '/').includes('/node_modules/')
            ) {
              return { path: Bun.resolveSync(args.path, args.resolveDir) }
            }
            const guidance = args.path.startsWith('@ankole/uikit/')
              ? 'Import components from "@ankole/uikit". Remove UIKit stylesheet imports; the Pod host already loads those styles.'
              : args.path.startsWith('@ankole/applet-sdk/')
                ? 'Import runtime APIs from "@ankole/applet-sdk". Use "import type" for SDK type subpaths.'
                : 'Use only the host React modules: react, react/jsx-runtime, react/jsx-dev-runtime, react-dom, react-dom/client.'
            throw new Error(`Unsupported applet host import "${args.path}". ${guidance}`)
          })
          build.onLoad({ filter: /.*/, namespace: 'applet' }, async () => ({
            contents: `import { provider } from ${JSON.stringify(join(directory, 'src/main.tsx'))};\nexport { provider };\nparent.__ANKOLE_APPLET_HOST__.mount(window, provider);\n${
              (await Bun.file(join(directory, 'src/style.css')).exists())
                ? `import ${JSON.stringify(join(directory, 'src/style.css'))};`
                : ''
            }`,
            loader: 'tsx',
            resolveDir: directory
          }))
        }
      }
    ],
    outdir,
    target: 'browser',
    format: 'esm',
    splitting: true,
    naming: { entry: 'main.[ext]', chunk: 'chunks/[name]-[hash].[ext]', asset: 'assets/[name]-[hash].[ext]' },
    jsx: { runtime: 'automatic', development: false },
    define: { 'process.env.NODE_ENV': '"production"' },
    external: appletHostModules
  }).catch(async error => {
    await rm(outdir, { recursive: true, force: true })
    throw appletBuildError('Applet frontend build failed', error)
  })
  if (!result.success) {
    await rm(outdir, { recursive: true, force: true })
    throw appletBuildError('Applet frontend build failed', result.logs)
  }
  for (const output of result.outputs) {
    if (
      output.path.endsWith('.js') &&
      /new\s+Worker\s*\(\s*new\s+URL\s*\(\s*["'][^"']+\.ts(?:[?#][^"']*)?["']/.test(await output.text())
    ) {
      await rm(outdir, { recursive: true, force: true })
      throw new Error('Import the Worker URL with ?url and pass new URL(workerURL, import.meta.url) to new Worker')
    }
  }
  const stylesheets = (await readdir(outdir, { recursive: true }))
    .sort()
    .filter(name => name.endsWith('.css'))
    .map(name => `<link rel="stylesheet" href="./${name}">`)
    .join('')
  await writeFile(
    join(outdir, 'index.html'),
    `<!doctype html><html><head>${stylesheets}<script type="module" src="./main.js"></script></head><body></body></html>`
  )
  const files: string[] = []
  for (const name of await readdir(outdir, { recursive: true })) {
    if ((await stat(join(outdir, name))).isFile()) files.push(`dist/${name}`)
  }
  const serverEntry = join(directory, 'src/server/main.ts')
  if (await Bun.file(serverEntry).exists()) {
    const server = await Bun.build({
      entrypoints: [serverEntry],
      target: 'node',
      format: 'esm',
      packages: 'bundle',
      splitting: false,
      naming: 'main.js',
      outdir: serverDirectory,
      plugins: [
        {
          name: 'applet-server-builtins',
          setup(build) {
            build.onResolve({ filter: /.*/ }, args => {
              if (isBuiltin(args.path)) {
                return { path: args.path.startsWith('node:') ? args.path : `node:${args.path}`, external: true }
              }
            })
          }
        }
      ]
    }).catch(async error => {
      await rm(serverDirectory, { recursive: true, force: true })
      throw appletBuildError('Applet backend build failed', error)
    })
    if (!server.success) {
      await rm(serverDirectory, { recursive: true, force: true })
      throw appletBuildError('Applet backend build failed', server.logs)
    }
    const output = await Bun.file(join(serverDirectory, 'main.js')).text()
    if (new Bun.Transpiler({ loader: 'js' }).scanImports(output).some(item => !item.path.startsWith('node:'))) {
      await rm(serverDirectory, { recursive: true, force: true })
      throw new Error('Applet backend must bundle all imports except node:* builtins')
    }
    files.push('server/main.js')
  }
  return { directory, files }
}

export async function commandFromArgs(args: string[], cwd = process.cwd()) {
  if (args[0] === 'jobs' && ['schedules', 'webhooks'].includes(args[1] ?? '') && args[2]) {
    args = [`jobs.${args[1]}.${args[2]}`, ...args.slice(3)]
  }
  if (args[0] === 'chat' && args[1] === 'attachment' && args[2] === 'get') {
    const [, , , conversationId, messageId, rawPosition, toFlag, destination] = args
    const position = Number(rawPosition)
    if (
      !conversationId ||
      !messageId ||
      !rawPosition ||
      !/^\d+$/.test(rawPosition) ||
      !Number.isSafeInteger(position) ||
      toFlag !== '--to' ||
      !destination ||
      args.length !== 8
    ) {
      throw new Error('Use chat attachment get <conversation-id> <message-id> <position> --to <worker-path>')
    }
    return {
      operation: 'chat.attachment.get',
      params: {
        conversation_id: conversationId,
        message_id: messageId,
        position,
        local_path: destination
      },
      cwd
    }
  }
  if (args[0] === 'comments') {
    return parseCommentsCommand(args.slice(1), cwd)
  }
  if (args[0] === 'office') {
    return parseOfficeCommand(args.slice(1), cwd)
  }
  if (args[0] === 'office.render') {
    return parseOfficeRenderOperation(args.slice(1), cwd)
  }
  if (args[0] === 'page' && args[1] === 'update-sharing') {
    if (!args[2] || !args[3]) throw new Error('Use page update-sharing <page-id> <JSON body>')
    return { operation: 'pages.update_sharing', params: { ...parseParams(args[3]), id: args[2] }, cwd }
  }
  if (args[0] === 'page' && args[1] === 'set-sharing') {
    const id = args[2]
    if (!id) throw new Error('Use page set-sharing <page-id> <JSON body> or sharing flags')
    let params: Record<string, unknown> = {}
    for (let index = 3; index < args.length; index++) {
      const argument = args[index]!
      if (argument === '--input') {
        const path = args[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (argument === '--sharing-version') {
        const version = args[++index]
        if (!version) throw new Error('--sharing-version requires a value')
        params.sharing_version = version
      } else if (argument === '--inherit-permissions') {
        const value = args[++index]
        if (value !== 'true' && value !== 'false') throw new Error('--inherit-permissions requires true or false')
        params.inherit_permissions = value === 'true'
      } else if (argument === '--grants') {
        const value = args[++index]
        if (!value) throw new Error('--grants requires a JSON array')
        const grants: unknown = JSON.parse(value)
        if (!Array.isArray(grants)) throw new Error('--grants requires a JSON array')
        params.grants = grants
      } else if (argument.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(argument) }
      } else throw new Error(`Unknown sharing argument: ${argument}`)
    }
    return { operation: 'pages.set_sharing', params: { ...params, id }, cwd }
  }
  if (args[0] === 'applet') {
    const [, action, directory, json] = args
    if (action === 'call') {
      if (!directory || args.length !== 3) throw new Error('Use applet call <JSON parameters>')
      return { operation: 'applets.call', params: parseParams(directory), cwd }
    }
    if (!directory || args.length > (['publish', 'pull'].includes(action ?? '') ? 4 : 3)) {
      throw new Error('Use applet init|build|publish|pull <directory> [JSON parameters]')
    }
    if (action === 'init') return { local: await initializeApplet(resolve(cwd, directory)) }
    if (action === 'build') return { local: await buildApplet(resolve(cwd, directory)) }
    if (action === 'pull') {
      if (!json) throw new Error('applet pull requires page id in JSON')
      return { operation: 'applets.pull', params: parseParams(json), cwd, pull_directory: directory }
    }
    if (action !== 'publish' || !json) throw new Error('applet publish requires page id and base_revision in JSON')
    return { operation: 'applets.publish', params: parseParams(json), cwd, publish_directory: directory }
  }
  if (args[0] === 'pages.search') {
    return parsePagesSearchCommand(args.slice(1), cwd)
  }
  const [operation, input, file] = args
  if (!operation || !input || args.length > (input === '--input' ? 3 : 2)) {
    throw new Error('Use <operation> <JSON parameters> or --input <JSON file>')
  }
  const json = input === '--input' ? await readFile(resolve(cwd, file ?? ''), 'utf8') : input
  return { operation, params: parseParams(json), cwd }
}

async function parsePagesSearchCommand(rest: string[], cwd: string) {
  if (rest.length === 0) {
    throw new Error('Use pages.search <JSON parameters>, --input <JSON file>, or [<query>] [search flags]')
  }
  if (rest.length === 1 && rest[0]!.trimStart().startsWith('{')) {
    const parsed = parseParams(rest[0]!)
    return {
      operation: 'pages.search',
      params: parsed.domain === undefined ? { domain: 'all', ...parsed } : parsed,
      cwd
    }
  }
  if (rest[0] === '--input' && rest.length === 2) {
    const parsed = parseParams(await readFile(resolve(cwd, rest[1]!), 'utf8'))
    return {
      operation: 'pages.search',
      params: parsed.domain === undefined ? { domain: 'all', ...parsed } : parsed,
      cwd
    }
  }
  const params: Record<string, unknown> = { domain: 'all' }
  let positionalQuery: string | undefined
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index]!
    if (arg === '--query' || arg === '-q') {
      const value = rest[++index]
      if (value === undefined) throw new Error(`${arg} requires a value`)
      params.query = value
    } else if (arg === '--domain') {
      const value = rest[++index]
      if (!value || !['all', 'pages', 'brain'].includes(value)) {
        throw new Error('--domain must be all, pages, or brain')
      }
      params.domain = value
    } else if (arg === '--type' || arg === '--types') {
      const value = rest[++index]
      if (!value) throw new Error(`${arg} requires a value`)
      params.types = value
    } else if (arg === '--scope') {
      const value = rest[++index]
      if (!value || !['all', 'private', 'space', 'shared', 'conversation'].includes(value)) {
        throw new Error('--scope must be all, private, space, shared, or conversation')
      }
      params.scope = value
    } else if (arg === '--ancestor' || arg === '--ancestor-id') {
      const value = rest[++index]
      if (!value) throw new Error(`${arg} requires a page id`)
      params.ancestor_id = value
    } else if (arg === '--created-by') {
      const value = rest[++index]
      if (!value) throw new Error('--created-by requires a principal uid')
      params.created_by = value
    } else if (arg === '--updated-after') {
      const value = rest[++index]
      if (!value) throw new Error('--updated-after requires an ISO-8601 timestamp')
      params.updated_after = value
    } else if (arg === '--title-only') {
      params.title_only = true
    } else if (arg === '--sort') {
      const value = rest[++index]
      if (!value || !['best', 'updated_desc', 'updated_asc', 'created_desc', 'created_asc'].includes(value)) {
        throw new Error('--sort must be best, updated_desc, updated_asc, created_desc, or created_asc')
      }
      params.sort = value
    } else if (arg === '--limit') {
      const limit = decimalPositiveInteger(rest[++index], '--limit')
      if (limit > 100) throw new Error('--limit must be at most 100')
      params.limit = limit
    } else if (!arg.startsWith('-') && positionalQuery === undefined && params.query === undefined) {
      positionalQuery = arg
    } else {
      throw new Error(`Unknown pages.search argument: ${arg}`)
    }
  }
  if (params.query === undefined) {
    params.query = positionalQuery ?? ''
  }
  return { operation: 'pages.search', params, cwd }
}

function parseCommentsCommand(rest: string[], cwd: string) {
  const [subcommand, ...tail] = rest
  if (subcommand === 'list') {
    let id: string | undefined
    let status: string | undefined
    let cursor: string | undefined
    let limit: number | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--status') {
        const value = tail[++index]
        if (!value || !['open', 'resolved', 'all', 'unread'].includes(value)) {
          throw new Error('--status must be open, resolved, all, or unread')
        }
        status = value
      } else if (arg === '--cursor') {
        cursor = tail[++index]
        if (!cursor) throw new Error('--cursor requires a value')
      } else if (arg === '--limit') {
        limit = decimalPositiveInteger(tail[++index], '--limit')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else {
        throw new Error(`Unknown comments list argument: ${arg}`)
      }
    }
    if (!id) {
      throw new Error(
        'Use comments list <page-id> [--status open|resolved|all|unread] [--cursor <token>] [--limit <n>]'
      )
    }
    return {
      operation: 'comments.list',
      params: {
        id,
        ...(status ? { status } : {}),
        ...(cursor ? { cursor } : {}),
        ...(limit !== undefined ? { limit } : {})
      },
      cwd
    }
  }
  if (subcommand === 'show') {
    let id: string | undefined
    let commentId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--comment') {
        commentId = tail[++index]
        if (!commentId) throw new Error('--comment requires a comment id')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !commentId) {
        commentId = arg
      } else {
        throw new Error(`Unknown comments show argument: ${arg}`)
      }
    }
    if (!id || !commentId) throw new Error('Use comments show <page-id> <comment-id>')
    return { operation: 'comments.show', params: { id, comment_id: commentId }, cwd }
  }
  if (subcommand === 'reply') {
    let id: string | undefined
    let rootId: string | undefined
    let body: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--root') {
        rootId = tail[++index]
        if (!rootId) throw new Error('--root requires a root comment id')
      } else if (arg === '--body') {
        body = tail[++index]
        if (!body) throw new Error('--body requires text')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !rootId) {
        rootId = arg
      } else if (!arg.startsWith('-') && body === undefined) {
        body = arg
      } else {
        throw new Error(`Unknown comments reply argument: ${arg}`)
      }
    }
    if (!id || !rootId || !body || !body.trim()) {
      throw new Error('Use comments reply <page-id> <root-comment-id> <body>')
    }
    return { operation: 'comments.reply', params: { id, root_id: rootId, body }, cwd }
  }
  if (subcommand === 'resolve') {
    let id: string | undefined
    let commentId: string | undefined
    let version: number | undefined
    let resolved = true
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--comment') {
        commentId = tail[++index]
        if (!commentId) throw new Error('--comment requires a comment id')
      } else if (arg === '--version') {
        version = decimalPositiveInteger(tail[++index], '--version')
      } else if (arg === '--reopen') {
        resolved = false
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !commentId) {
        commentId = arg
      } else {
        throw new Error(`Unknown comments resolve argument: ${arg}`)
      }
    }
    if (!id || !commentId || version === undefined) {
      throw new Error('Use comments resolve <page-id> <comment-id> --version <n> [--reopen]')
    }
    return { operation: 'comments.resolve', params: { id, comment_id: commentId, version, resolved }, cwd }
  }
  throw new Error('Use comments list|show|reply|resolve ...')
}

async function parseOfficeRenderOperation(rest: string[], cwd: string) {
  let params: Record<string, unknown> = {}
  let destination: string | undefined
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index]!
    if (arg === '--input') {
      const path = rest[++index]
      if (!path) throw new Error('--input requires a JSON file')
      params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
    } else if (arg === '--to') {
      destination = rest[++index]
      if (!destination) throw new Error('--to requires a destination path')
    } else if (arg.trimStart().startsWith('{')) {
      params = { ...params, ...parseParams(arg) }
    } else {
      throw new Error(`Unknown office.render argument: ${arg}`)
    }
  }
  const localPath = destination ?? (typeof params.local_path === 'string' ? params.local_path : undefined)
  if (!localPath || typeof params.id !== 'string') {
    throw new Error('Use office.render <JSON parameters> --to <worker-path>')
  }
  return { operation: 'office.render', params: { ...params, local_path: localPath }, cwd }
}

async function parseOfficeCommand(rest: string[], cwd: string) {
  const [subcommand, ...tail] = rest
  if (subcommand === 'inspect') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--sheet') {
        const value = tail[++index]
        if (!value) throw new Error('--sheet requires a sheet name')
        params.sheet = value
      } else if (arg === '--sheet-id') {
        params.sheet_id = decimalPositiveInteger(tail[++index], '--sheet-id')
      } else if (arg === '--range') {
        const value = tail[++index]
        if (!value) throw new Error('--range requires an A1 range')
        params.range = value
      } else if (arg === '--story') {
        const value = tail[++index]
        if (!value) throw new Error('--story requires a story identifier')
        params.story = value.trimStart().startsWith('{') ? JSON.parse(value) : value
      } else if (arg === '--from') {
        params.from_block = decimalNonNegativeInteger(tail[++index], '--from')
      } else if (arg === '--to') {
        params.to_block = decimalNonNegativeInteger(tail[++index], '--to')
      } else if (arg === '--from-slide') {
        params.from_slide = decimalNonNegativeInteger(tail[++index], '--from-slide')
      } else if (arg === '--to-slide') {
        params.to_slide = decimalNonNegativeInteger(tail[++index], '--to-slide')
      } else if (arg === '--slide-id') {
        params.slide_id = decimalPositiveInteger(tail[++index], '--slide-id')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office inspect argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office inspect <page-id> [flags or JSON]')
    }
    return { operation: 'office.inspect', params, cwd }
  }
  if (subcommand === 'render') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    let destination: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--page') {
        params.page = decimalPositiveInteger(tail[++index], '--page')
      } else if (arg === '--slide') {
        params.slide = decimalPositiveInteger(tail[++index], '--slide')
      } else if (arg === '--scale') {
        const raw = tail[++index]
        const scale = Number(raw)
        if (!raw || !Number.isFinite(scale) || scale <= 0 || scale > 4) {
          throw new Error('--scale requires a number in (0, 4]')
        }
        params.scale = scale
      } else if (arg === '--to') {
        destination = tail[++index]
        if (!destination) throw new Error('--to requires a destination path')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office render argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    const localPath = destination ?? (typeof params.local_path === 'string' ? params.local_path : undefined)
    if (
      typeof params.id !== 'string' ||
      !params.id ||
      !localPath ||
      (params.page === undefined && params.slide === undefined)
    ) {
      throw new Error('Use office render <page-id> (--page <n> | --slide <n>) [--scale <n>] --to <worker-path>')
    }
    return { operation: 'office.render', params: { ...params, local_path: localPath }, cwd }
  }
  if (subcommand === 'commands') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    let positionalQuery: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--query' || arg === '-q') {
        const value = tail[++index]
        if (value === undefined) throw new Error(`${arg} requires a value`)
        params.query = value
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else if (!arg.startsWith('-') && positionalQuery === undefined && params.query === undefined) {
        positionalQuery = arg
      } else {
        throw new Error(`Unknown office commands argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (params.query === undefined && positionalQuery !== undefined) params.query = positionalQuery
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office commands <page-id> [<query>]')
    }
    return { operation: 'office.commands', params, cwd }
  }
  if (subcommand === 'apply') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--expected-revision') {
        params.expected_revision = decimalNonNegativeInteger(tail[++index], '--expected-revision')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office apply argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (
      typeof params.id !== 'string' ||
      !params.id ||
      (!Array.isArray(params.commands) && !Array.isArray(params.ops))
    ) {
      throw new Error('Use office apply [<page-id>] \'<{"commands":[...]} or {"ops":[...]}>\'')
    }
    return { operation: 'office.apply', params, cwd }
  }
  if (subcommand === 'to-document' || subcommand === 'to_document') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--parent' || arg === '--parent-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a parent page id`)
        params.parent_id = value
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office to-document argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office to-document <page-id> [--parent <parent-id>]')
    }
    return { operation: 'office.to_document', params, cwd }
  }
  throw new Error('Use office inspect|render|commands|apply|to-document ...')
}

function decimalNonNegativeInteger(value: string | undefined, name: string): number {
  const parsed = Number(value)
  if (!value || !/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} requires a non-negative integer`)
  }
  return parsed
}

function decimalPositiveInteger(value: string | undefined, name: string): number {
  const parsed = Number(value)
  if (!value || !/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} requires a positive integer`)
  }
  return parsed
}

function parseParams(json: string) {
  const params: unknown = JSON.parse(json)
  if (!isRecord(params)) {
    throw new Error('Parameters must be a JSON object')
  }
  return params as Record<string, unknown>
}

if (import.meta.main) {
  installStdoutEpipeGuard(process.stdout)
  try {
    const args = process.argv.slice(2)
    if (args.length === 0 || helpRequested(args)) {
      markHelpSeen({ commandKey: 'ankole-pod' })
      process.stdout.write(`${POD_CLI_HELP}\n`)
    } else {
      const command = await commandFromArgs(args)
      if ('local' in command) {
        await emitFirstUseGuidance({ commandKey: 'ankole-pod', guidance: POD_FIRST_USE_GUIDANCE })
        process.stdout.write(`${JSON.stringify(command.local, null, 2)}\n`)
      } else {
        const socket = process.env[POD_CLI_SOCKET_ENV]
        if (!socket) throw new Error('ankole-pod requires an active Ankole turn')
        await emitFirstUseGuidance({ commandKey: 'ankole-pod', guidance: POD_FIRST_USE_GUIDANCE })
        const result = await requestSocketLineBridge(socket, JSON.stringify(command), 'Invalid Pod bridge response')
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
      }
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n`)
    process.exitCode = 1
  }
}
