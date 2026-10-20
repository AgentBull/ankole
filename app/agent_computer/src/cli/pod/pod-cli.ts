import { mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { isBuiltin } from 'node:module'
import { POD_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import { errorMessage, nodeErrorCode } from '../../common/errors'

export const POD_CLI_HELP = `ankole-pod — durable pages and data in your Pod

Run only inside an active Ankole turn. Every operation uses your Agent's
Principal permissions. If access is denied, ask a member to share the page
or add your Agent to the space. Your caller's permissions are not inherited.

  ankole-pod <operation> '<JSON parameters>'
  ankole-pod <operation> --input <JSON file>
  ankole-pod applet init <directory>
  ankole-pod applet build <directory>
  ankole-pod applet call '<{"id":"page-id","method":"GET","path":"/orders","query":{}}>'
  ankole-pod applet publish <directory> '<{"id":"page-id","base_revision":0}>'

Read operations:
  pages.list       {scope?: space|private|shared|recent|favorites|trash, query?}
  pages.read       {id} — returns Markdown and the current page revision
  pages.sharing    {id}
  files.manifest   {id}
  database.tables  {id: database_page_id}
  database.schema  {id: table_id}
  database.query   {id, filter?, sort?, page_size?, page_token?, ids?}
  database.aggregate {id, filter?, group_by?, metrics}

Write operations:
  pages.create     {type: doc|database|applet|file, title, parent_id?, private_owner_uid?}
  pages.update     {id, title?, icon?}
  pages.move       {id, parent_id?, private_owner_uid?}
  pages.delete     {id} — moves the subtree into the trash
  pages.restore    {id}
  pages.write      {id, base_revision, markdown} — stale writes are rejected
  files.upload     {id, local_path, role: file|asset|attachment, base_revision?}
  database.create_table {id: database_page_id, name}
  database.create_field {id: table_id, name, type, config?}
  database.update_field {id: field_id, version, ...changes}
  database.delete_field {id: field_id, version}
  database.create_view  {id: table_id, name, type, config?}
  database.update_view  {id: view_id, version, ...changes}
  database.delete_view  {id: view_id, version}
  database.write    {id: table_id, creates?:[{data}], updates?:[{id,data,expected_versions}], deletes?:[{id,expected_versions}]}
  database.copy     {id: table_id, parent_id: report_page_id, filter?}
  applets.call      {id, method: GET|POST|PUT|PATCH|DELETE, path, query?, body?}
    Returns {status, body?, logs?}, including handler errors. Never replay a
    write after a disconnect: first read its saved result.

Database parameter shapes:
  Read database.schema before writing; data keys and field_id values are the
  returned field UUIDs, not field names. Reuse the saved page and table IDs.
  filter: {conjunction:"and"|"or", conditions:[{field_id, operator, value?}]}
    operator: is|contains|is_empty|is_not_empty|gt|gte|lt|lte|text_contains
  sort: [{field_id, direction:"asc"|"desc"}]
  group_by: [{field_id, bucket?:"day"|"week"|"month"|"quarter"|"year"}]
  metrics: [{operation:"count"|"sum"|"avg"|"min"|"max", field_id?, alias}]
    field_id is required except for row count. For example:
    {"id":"TABLE_ID","metrics":[{"operation":"sum","field_id":"FIELD_ID","alias":"total"}]}
    Results contain groups:[{values,metrics:{total:...}}] and data_version.
  query results: {records:[{id,data,versions,...}],complete,page_token,data_version}
    When complete is false, pass page_token to the next query with the same
    filter and sort. Aggregate calculates over all matching rows.
  data: {"FIELD_ID": value}; expected_versions: {"FIELD_ID": last_read_version}
    An unwritten field has no expected_versions entry. Creates need no versions.
  field type: text|number|select|datetime|checkbox|user|attachment|auto_number|
    link|formula|created_at|updated_at|created_by|updated_by
    formula config: {source:"[Price] * [Quantity]"}; formulas are read-only.
    select config: {multiple?:boolean,options:[{id,name}]}; records store option IDs.
    link config: {table_id,multiple?:boolean,bidirectional?:boolean}.
    datetime values use ISO 8601; user values are arrays of Principal UIDs.
  view type: grid|kanban|gallery

Page access:
  Pass parent_id to pages.create to create a child directly. This requires
  edit access to the parent document. The child inherits its permissions;
  creating a page does not grant its creator Full access (manage).
  Editing content, title, or icon requires edit access. An editor can move a
  page when its subtree's access stays unchanged. A move that changes access
  requires Full access (manage) to the source page. Moving under a document
  also requires edit access to that document. Deleting a page or changing its
  sharing requires Full access (manage) to that page.

Always read before updating. A record patch carries versions for the fields
it changes; record deletion carries the whole versions map. A conflict means
read again and reconsider the change. Do not retry an old write blindly.
Use ankole-files get pages/<page-id>/<path> --pod to read a page file.

Applets export provider = defineApplet(App) from src/main.tsx, use the Pod
components and @ankole/applet-sdk hooks, and save business data in Database.
Applet init accepts a new directory or an existing empty directory.
The Worker includes the actual SDK at /repo/libs/applet-sdk/src/index.tsx
and its query, aggregate, and record types at /repo/libs/applet-sdk/src/types.ts.
Frontend build emits CommonJS and dist/index.html. Import components from the
root "@ankole/uikit" export, and runtime APIs from "@ankole/applet-sdk".
Do not import their runtime subpaths or UIKit styles; the Pod host supplies styles.
SDK type subpaths remain available through "import type".
Optional src/server/main.ts
exports a default route table typed with import type { Routes } from
'@ankole/applet-sdk/server'. Build bundles it into server/main.js as browser ESM,
with no external imports. The sandbox has AnkoleRuntime db, file, ai and HttpError;
it has no network, Node, timers or secrets. GET handlers cannot write.
Use useRoute/useRouteMutation in the frontend; route writes do not refresh queries
unless the applet explicitly invalidates them. Publish checks base_revision and
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
    `import { defineApplet } from '@ankole/applet-sdk'\n\nfunction App() {\n  return <main><h1>新小程序</h1><p>使用 Database 保存业务数据。</p></main>\n}\n\nexport const provider = defineApplet(App)\n`,
    { flag: 'wx' }
  )
  await writeFile(join(directory, 'src/style.css'), '.ankole-applet { padding: 1rem; }\n', { flag: 'wx' })
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

// A publication mounts from a Blob URL. Embed imported media so JS and CSS do not
// resolve asset paths against that URL or against a later publication.
const appletAssetPattern =
  /\.(?:png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp3|mp4|webm|ogg|wav|pdf|wasm|bin)(?:[?#].*)?$/i

async function appletAssetURL(path: string) {
  const [filename, fragment] = path.split('#', 2)
  const file = Bun.file(filename!.split('?', 1)[0]!)
  const data = Buffer.from(await file.arrayBuffer()).toString('base64')
  return `data:${file.type};base64,${data}${fragment ? `#${fragment}` : ''}`
}

export async function buildApplet(directory: string) {
  const outdir = join(directory, 'dist')
  const serverDirectory = join(directory, 'server')
  await rm(serverDirectory, { recursive: true, force: true })
  await rm(outdir, { recursive: true, force: true })
  await mkdir(outdir, { recursive: true })
  const result = await Bun.build({
    entrypoints: ['ankole-applet-entry'],
    plugins: [
      {
        name: 'applet-entry',
        setup(build) {
          build.onResolve({ filter: /^ankole-applet-entry$/ }, () => ({ path: 'app', namespace: 'applet' }))
          build.onResolve({ filter: appletAssetPattern }, async args => {
            if (!args.importer.endsWith('.css') || /^(?:[a-z][\w+.-]*:|\/\/|#)/i.test(args.path)) return
            return { path: await appletAssetURL(resolve(args.resolveDir, args.path)), external: true }
          })
          build.onLoad({ filter: appletAssetPattern, namespace: 'file' }, async args => ({
            contents: `export default ${JSON.stringify(await appletAssetURL(args.path))}`,
            loader: 'js'
          }))
          build.onResolve({ filter: /^(?:react|react-dom|@ankole\/(?:uikit|applet-sdk))\// }, args => {
            if (appletHostModules.includes(args.path)) return
            const guidance = args.path.startsWith('@ankole/uikit/')
              ? 'Import components from "@ankole/uikit". Remove UIKit stylesheet imports; the Pod host already loads those styles.'
              : args.path.startsWith('@ankole/applet-sdk/')
                ? 'Import runtime APIs from "@ankole/applet-sdk". Use "import type" for SDK type subpaths.'
                : 'Use only the host React modules: react, react/jsx-runtime, react/jsx-dev-runtime, react-dom, react-dom/client.'
            throw new Error(`Unsupported applet host import "${args.path}". ${guidance}`)
          })
          build.onLoad({ filter: /.*/, namespace: 'applet' }, async () => ({
            contents: `export * from ${JSON.stringify(join(directory, 'src/main.tsx'))};\n${
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
    format: 'cjs',
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
    if (output.path.endsWith('.js')) await rename(output.path, join(outdir, 'app.js'))
    else if (output.path.endsWith('.css')) await rename(output.path, join(outdir, 'app.css'))
  }
  if (!(await Bun.file(join(outdir, 'app.css')).exists())) await writeFile(join(outdir, 'app.css'), '')
  await writeFile(
    join(outdir, 'index.html'),
    '<!doctype html><html><head><link rel="stylesheet" href="./app.css"><script src="./app.js"></script></head><body></body></html>'
  )
  const files = (await readdir(outdir)).map(name => `dist/${name}`)
  const serverEntry = join(directory, 'src/server/main.ts')
  if (await Bun.file(serverEntry).exists()) {
    const server = await Bun.build({
      entrypoints: [serverEntry],
      target: 'browser',
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
              if (isBuiltin(args.path)) throw new Error(`Applet backend cannot import Node built-in: ${args.path}`)
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
    if (new Bun.Transpiler({ loader: 'js' }).scanImports(output).length > 0) {
      await rm(serverDirectory, { recursive: true, force: true })
      throw new Error('Applet backend must bundle all imports; dynamic module loading is not supported')
    }
    files.push('server/main.js')
  }
  return { directory, files }
}

export async function commandFromArgs(args: string[], cwd = process.cwd()) {
  if (args[0] === 'applet') {
    const [, action, directory, json] = args
    if (action === 'call') {
      if (!directory || args.length !== 3) throw new Error('Use applet call <JSON parameters>')
      return { operation: 'applets.call', params: parseParams(directory), cwd }
    }
    if (!directory || args.length > (action === 'publish' ? 4 : 3)) {
      throw new Error('Use applet init|build|publish <directory> [JSON parameters]')
    }
    if (action === 'init') return { local: await initializeApplet(resolve(cwd, directory)) }
    if (action === 'build') return { local: await buildApplet(resolve(cwd, directory)) }
    if (action !== 'publish' || !json) throw new Error('applet publish requires page id and base_revision in JSON')
    return { operation: 'applets.publish', params: parseParams(json), cwd, publish_directory: directory }
  }
  const [operation, input, file] = args
  if (!operation || !input || args.length > (input === '--input' ? 3 : 2)) {
    throw new Error('Use <operation> <JSON parameters> or --input <JSON file>')
  }
  const json = input === '--input' ? await readFile(resolve(cwd, file ?? ''), 'utf8') : input
  return { operation, params: parseParams(json), cwd }
}

function parseParams(json: string) {
  const params: unknown = JSON.parse(json)
  if (!params || typeof params !== 'object' || Array.isArray(params)) {
    throw new Error('Parameters must be a JSON object')
  }
  return params as Record<string, unknown>
}

if (import.meta.main) {
  try {
    const args = process.argv.slice(2)
    if (args.length === 0 || args.includes('--help') || args.includes('-h')) process.stdout.write(`${POD_CLI_HELP}\n`)
    else {
      const command = await commandFromArgs(args)
      if ('local' in command) process.stdout.write(`${JSON.stringify(command.local, null, 2)}\n`)
      else {
        const socket = process.env[POD_CLI_SOCKET_ENV]
        if (!socket) throw new Error('ankole-pod is available only inside an active Ankole turn')
        const result = await requestSocketLineBridge(socket, JSON.stringify(command), 'Invalid Pod bridge response')
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
      }
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n`)
    process.exitCode = 1
  }
}
