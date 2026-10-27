import { mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { isBuiltin } from 'node:module'
import type { BunPlugin } from 'bun'
import { POD_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import { errorMessage, nodeErrorCode } from '../../common/errors'

export const POD_CLI_HELP = `ankole-pod — durable pages and data in your Pod

Run inside an active Ankole turn or AutomationJob attempt. Each operation uses the Agent's
Principal permissions. If access is denied, ask a member to share the page
or add your Agent to the space. Interactive access uses Human ∩ Agent permissions.

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
  pages.search     {query, required_action?, exclude_subtree_of?} — searches titles and document text, up to 30 matches
  pages.read       {id} — returns Markdown and the current page revision
  pages.sharing    {id}
  files.manifest   {id}
  base.tables  {id: base_page_id}
  base.schema  {id: table_id}
  base.query   {id, filter?, sort?, page_size?, page_token?, ids?}
  base.aggregate {id, filter?, group_by?, metrics}

Write operations:
  pages.set_sharing {id, sharing_version, inherit_permissions?, grants?} — requires manage access
  pages.create     {type: doc|base|applet|file, title, parent_id?, private_owner_uid?}
  pages.update     {id, title?, icon?}
  pages.move       {id, parent_id?, private_owner_uid?}
  pages.delete     {id} — moves the subtree into the trash
  pages.restore    {id}
  pages.write      {id, base_revision, markdown} — stale writes are rejected
  pages.append     {id, base_revision, markdown}
  pages.patch      {id, base_revision, edits:[{old_text,new_text,replace_all?}]}
  files.upload     {id, local_path, role: file|asset|attachment, base_revision?}
  base.create_table {id: base_page_id, name}
  base.delete_table {id: table_id} — requires manage access
  base.create_field {id: table_id, name, type, config?}
  base.update_field {id: field_id, version, ...changes}
  base.delete_field {id: field_id, version}
  base.create_view  {id: table_id, name, type, config?}
  base.update_view  {id: view_id, version, ...changes}
  base.delete_view  {id: view_id, version}
  base.write    {id: table_id, creates?:[{data}], updates?:[{id,data,expected_versions}], deletes?:[{id,expected_versions}]}
  base.copy     {id: table_id, parent_id: report_page_id, filter?}
  applets.call      {id, method: GET|POST|PUT|PATCH|DELETE, path, query?, body?}
    Returns {status, body?, logs?}, including handler errors. Never replay a
    write after a disconnect: first read its saved result.

Base parameter shapes:
  Read base.schema before writing; data keys and field_id values are the
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
  view reads page content and records. contribute also writes records and
  uploads record attachments. edit changes documents, schemas, and Applet
  source. manage also changes sharing, deletes tables, and uses the trash.
  Pass parent_id to pages.create to create a child directly. This requires
  edit access to the parent page. The child inherits its permissions;
  creating a page does not grant its creator Full access (manage).
  Editing content, title, or icon requires edit access. An editor can move a
  page when its subtree's access stays unchanged. A move that changes access
  requires Full access (manage) to the source page. Moving under a page
  also requires edit access to that page. Deleting a page or changing its
  sharing requires Full access (manage) to that page.

Always read before updating. A record patch carries versions for the fields
it changes; record deletion carries the whole versions map. A conflict means
read again and reconsider the change. Do not retry an old write blindly.
Use ankole-files get pages/<page-id>/<path> --pod to read a page file.

Applets export provider = defineApplet(App) from src/main.tsx, use the Pod
components and @ankole/applet-sdk hooks, and save business data in Base.
Applet init accepts a new directory or an existing empty directory.
The Worker includes the actual SDK at /repo/libs/applet-sdk/src/index.tsx
and its query, aggregate, and record types at /repo/libs/applet-sdk/src/types.ts.
Frontend build emits browser ESM chunks and dist/index.html. Import components from the
root "@ankole/uikit" export, and runtime APIs from "@ankole/applet-sdk".
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
The runtime provides Node builtins, temporary /tmp files, fetch, process.env from
applet.env.json, and AnkoleRuntime base, file, ai and HttpError. GET handlers cannot write.
Applet pull restores source and package files, then runs bun install --ignore-scripts.
Use useRoute/useRouteMutation in the frontend; route writes do not refresh queries
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
    `import { defineApplet } from '@ankole/applet-sdk'\n\nfunction App() {\n  return <main><h1>新小应用</h1><p>使用 Base 保存业务数据。</p></main>\n}\n\nexport const provider = defineApplet(App)\n`,
    { flag: 'wx' }
  )
  await writeFile(join(directory, 'src/style.css'), '.ankole-applet { padding: 1rem; }\n', { flag: 'wx' })
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
        if (!socket) throw new Error('ankole-pod requires an active Ankole turn or AutomationJob attempt')
        const result = await requestSocketLineBridge(socket, JSON.stringify(command), 'Invalid Pod bridge response')
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
      }
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n`)
    process.exitCode = 1
  }
}
