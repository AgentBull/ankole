import { mkdir, readFile, readdir, realpath, rm, stat, writeFile } from 'node:fs/promises'
import { isBuiltin } from 'node:module'
import { join, resolve } from 'node:path'
import type { BunPlugin } from 'bun'
import { nodeErrorCode } from '../../common/errors'

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
