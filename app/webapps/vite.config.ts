import path from 'node:path'
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { gzipSync } from 'node:zlib'
import {
  artifactRoot,
  assetsDirectory,
  edition,
  editionAssetAliases,
  internalsRoot,
  localeDirectory,
  prepareEdition,
  prepareLocales,
  repositoryRoot,
  webappEntries
} from './scripts/edition.ts'
import { fileURLToPath } from 'node:url'
import postcss from 'postcss'
import babel from '@rolldown/plugin-babel'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig, type Plugin, type UserConfig, type ViteDevServer } from 'vite'

const filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(filename)
const outputPath = assetsDirectory
prepareEdition()
const devServerOrigin = 'http://127.0.0.1:3035'
const phoenixShutdownGraceMs = 2_000
const phoenixRestartGuardKey = Symbol.for('ankole.vite.phoenix-restart-guard')
let phoenixShutdownGuardInstalled = false

const entries = {
  ...webappEntries(),
  ...Object.fromEntries(
    ['react', 'react-jsx-runtime', 'react-jsx-dev-runtime', 'react-dom', 'react-dom-client', 'uikit', 'applet-sdk'].map(
      name => [`applet-${name}`, path.join(dirname, `entrypoints/applet-vendor/${name}.ts`)]
    )
  )
}
const phoenixPort = process.env.PORT || '4000'
const saasDomain = (process.env.ANKOLE_SAAS_DOMAIN || 'ankole.localhost').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const saasOrigins =
  edition === 'saas' ? [new RegExp(`^http://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.${saasDomain}:${phoenixPort}$`)] : []

// Keep Markdown dependencies separate from routes that do not use the renderer
// or the document editor's Markdown import and export.
const markdownPipelinePrefixes = [
  'character-entities',
  'hast-util-',
  'mdast-util-',
  'micromark',
  'remark-',
  'unist-util-',
  'vfile'
]
const markdownPipelinePackages = new Set([
  '@types/hast',
  '@types/mdast',
  '@ungap/structured-clone',
  'bail',
  'ccount',
  'comma-separated-tokens',
  'decode-named-character-reference',
  'devlop',
  'estree-util-is-identifier-name',
  'html-url-attributes',
  'inline-style-parser',
  'is-plain-obj',
  'longest-streak',
  'markdown-table',
  'property-information',
  'react-markdown',
  'space-separated-tokens',
  'style-to-js',
  'style-to-object',
  'trim-lines',
  'trough',
  'unified',
  'zwitch'
])

function nodeModulePackageName(moduleID: string): string | undefined {
  // The last `/node_modules/` segment names the real package even under the
  // Bun store layout (`node_modules/.bun/<pkg>@<v>/node_modules/<pkg>/…`).
  const tail = moduleID.split('/node_modules/').at(-1)
  if (!tail || tail === moduleID) return undefined
  const [first, second] = tail.split('/')
  return first?.startsWith('@') ? (second ? `${first}/${second}` : undefined) : first
}

function manualChunks(moduleID: string): string | undefined {
  if (/\.css(?:$|[?&])/i.test(moduleID)) return undefined
  const packageName = nodeModulePackageName(moduleID)
  if (!packageName) return undefined
  if (packageName === 'react' || packageName === 'react-dom' || packageName === 'scheduler') {
    return 'vendor-react'
  }
  if (
    packageName === '@tanstack/react-router' ||
    packageName === '@tanstack/router-core' ||
    packageName === '@tanstack/history'
  ) {
    return 'vendor-router'
  }

  // Keep dynamic-import-only editor, graph, chart, and Markdown dependencies in lazy chunks.
  if (moduleID.includes('/any-ascii/')) return 'vendor-transliteration'
  if (moduleID.includes('/json-edit-react/')) return 'vendor-json-editor'
  if (moduleID.includes('/xlsx/')) return 'vendor-spreadsheet'
  if (moduleID.includes('/@office-kit/') || moduleID.includes('/fflate/')) return 'vendor-presentation'
  if (packageName === 'lightweight-charts' || packageName === 'fancy-canvas') return 'vendor-charts'
  if (packageName === '@antv/infographic') return 'vendor-infographic'
  if (packageName === '@antv/g6' || packageName === 'bubblesets-js' || packageName === 'is-any-array') {
    return 'vendor-graph'
  }
  if (packageName === '@antv/g2') return 'vendor-g2'
  if (
    markdownPipelinePackages.has(packageName) ||
    markdownPipelinePrefixes.some(prefix => packageName.startsWith(prefix))
  ) {
    return 'vendor-markdown'
  }

  if (
    packageName === 'zod' ||
    moduleID.includes('/@tanstack/query-core/') ||
    moduleID.includes('/@tanstack/react-query/') ||
    moduleID.includes('/@preact/signals-core/') ||
    moduleID.includes('/@preact/signals-react/') ||
    moduleID.includes('/i18next/') ||
    moduleID.includes('/react-i18next/') ||
    moduleID.includes('/html-parse-stringify/')
  ) {
    return 'vendor-data'
  }

  if (
    moduleID.includes('/@base-ui/') ||
    moduleID.includes('/@floating-ui/') ||
    moduleID.includes('/@fluentui/react-icons/') ||
    packageName === '@tanstack/react-form' ||
    packageName === '@tanstack/form-core' ||
    packageName === '@tanstack/react-store' ||
    packageName === '@tanstack/store' ||
    packageName === '@tanstack/pacer-lite' ||
    packageName === '@tanstack/devtools-event-client' ||
    packageName === 'use-sync-external-store'
  ) {
    return 'vendor-setup-ui'
  }

  return 'vendor-utilities'
}

function phoenixShellPlugin(): Plugin {
  return {
    name: 'ankole-phoenix-shell',
    configureServer(server) {
      // Phoenix starts Vite as a watcher process. Keep stdin active so Vite can
      // notice when the parent port closes and exit instead of leaving the port
      // occupied after mix phx.server stops.
      process.stdin.resume()
      installPhoenixShutdownGuard()
      installPhoenixRestartGuard(server)
      server.watcher.add(path.join(repositoryRoot, 'app/locales'))
      if (process.env.ANKOLE_EDITION === 'saas') server.watcher.add(path.join(internalsRoot, 'locales'))
    },
    handleHotUpdate({ file, modules, server }) {
      if (file.endsWith('.toml') && /\/locales\//.test(file)) {
        prepareLocales()
        server.ws.send({ type: 'full-reload' })
      }
      if (!/app\/control_plane\/lib\/ankole_web\/.*\.(eex|ex|heex)$/.test(file)) return

      // Phoenix live_reload owns Elixir/template reload behavior. If a Vite
      // plugin ever sees those files, update importers instead of turning the
      // Phoenix shell into a Vite full-page reload boundary.
      return [...modules].flatMap(module => (module.file === file ? [...module.importers] : [module]))
    }
  }
}

function installPhoenixShutdownGuard(): void {
  if (phoenixShutdownGuardInstalled) return
  phoenixShutdownGuardInstalled = true

  const forceExitAfterGrace = () => {
    forcedExitTimer()
  }
  process.once('SIGTERM', forceExitAfterGrace)
  process.stdin.once('end', forceExitAfterGrace)
}

function installPhoenixRestartGuard(server: ViteDevServer): void {
  const guarded = server as typeof server & { [key: symbol]: boolean | undefined }
  if (guarded[phoenixRestartGuardKey]) return
  guarded[phoenixRestartGuardKey] = true

  // A fresh watcher process is safer than a half-closed server: Phoenix owns
  // recreation, while Vite's in-process restart can wait forever on HMR peers.
  const restart = server.restart.bind(server)
  server.restart = async forceOptimize => {
    const timer = forcedExitTimer()
    try {
      await restart(forceOptimize)
    } finally {
      clearTimeout(timer)
    }
  }
}

function forcedExitTimer(): ReturnType<typeof setTimeout> {
  // Phoenix treats a clean watcher exit as intentional and does not respawn it.
  // A non-zero fallback exit asks the watcher supervisor to recreate the child.
  const timer = setTimeout(() => process.exit(1), phoenixShutdownGraceMs)
  timer.unref()
  return timer
}

export default defineConfig(({ command }): UserConfig => ({
  base: command === 'build' ? '/assets/' : '/',
  plugins: [
    {
      name: 'ankole-edition-styles',
      enforce: 'pre',
      transform(code, id) {
        const cleanId = id.split('?', 1)[0]!.replaceAll('\\', '/')
        if (
          edition === 'saas' &&
          (cleanId.endsWith('/webapps/common/styles.css') || cleanId.endsWith('/libs/uikit/src/styles.css'))
        ) {
          return `${code}\n@source ${JSON.stringify(path.join(internalsRoot, 'webapps'))};\n`
        }
      }
    },
    {
      // The pdf.js stylesheet also styles the editor, dialogs, and sidebar of the pdf.js app under generic class
      // names. Ankole keeps the rules of the layers that its viewer renders, in a cascade layer below its theme.
      name: 'ankole-pdfjs-viewer-styles',
      enforce: 'pre',
      transform(code, id) {
        if (!id.split('?', 1)[0]!.replaceAll('\\', '/').endsWith('/pdfjs-dist/web/pdf_viewer.css')) return
        const styles = postcss.parse(code)
        styles.each(node => {
          const rendered =
            node.type === 'rule' &&
            /^(:root|\.pdfViewer|\.canvasWrapper|\.textLayer|\.annotationLayer|:is\(\.annotationLayer)/.test(
              node.selector
            )
          if (!rendered) node.remove()
        })
        return `@layer pdfjs {\n${styles.toString()}\n}`
      }
    },
    react(),
    tailwindcss(),
    babel({
      presets: [reactCompilerPreset()]
    }),
    {
      name: 'ankole-precompressed-assets',
      apply: 'build',
      closeBundle(error) {
        if (error || !existsSync(outputPath)) return
        const manifestPath = path.join(outputPath, 'manifest.json')
        if (existsSync(manifestPath)) {
          const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Record<
            string,
            {
              isEntry?: boolean
              name?: string
              file?: string
              css?: string[]
              imports?: string[]
              dynamicImports?: string[]
            }
          >
          const lazyVizChunks = new Set(['vendor-g2', 'vendor-charts', 'vendor-graph', 'vendor-infographic'])
          const sccIndex = new Map<string, number>()
          const sccLowlink = new Map<string, number>()
          const sccStack: string[] = []
          const sccOnStack = new Set<string>()
          let nextSccIndex = 0
          const visitChunkScc = (key: string): void => {
            sccIndex.set(key, nextSccIndex)
            sccLowlink.set(key, nextSccIndex)
            nextSccIndex += 1
            sccStack.push(key)
            sccOnStack.add(key)
            for (const dep of manifest[key]?.imports ?? []) {
              if (!manifest[dep]) continue
              if (!sccIndex.has(dep)) {
                visitChunkScc(dep)
                sccLowlink.set(key, Math.min(sccLowlink.get(key)!, sccLowlink.get(dep)!))
              } else if (sccOnStack.has(dep)) {
                sccLowlink.set(key, Math.min(sccLowlink.get(key)!, sccIndex.get(dep)!))
              }
            }
            if (sccLowlink.get(key) === sccIndex.get(key)) {
              const component: string[] = []
              let member: string
              do {
                member = sccStack.pop()!
                sccOnStack.delete(member)
                component.push(member)
              } while (member !== key)
              if (component.length > 1) {
                throw new Error(
                  `Static JS chunk import cycle detected (${component.map(item => manifest[item]?.file ?? item).join(' <-> ')}). Avoid codeSplitting merge thresholds or manualChunks rules that merge across CJS/ESM layers.`
                )
              }
            }
          }
          for (const key of Object.keys(manifest)) {
            if (!sccIndex.has(key)) visitChunkScc(key)
          }
          const appletUikitCss = new Set<string>()
          const appletUikitEntry = manifest['entrypoints/applet-vendor/uikit.ts']
          if (appletUikitEntry) {
            const seenApplet = new Set<string>()
            const appletQueue = ['entrypoints/applet-vendor/uikit.ts']
            while (appletQueue.length > 0) {
              const key = appletQueue.shift()!
              if (seenApplet.has(key)) continue
              seenApplet.add(key)
              const chunk = manifest[key]
              if (!chunk) continue
              for (const cssFile of chunk.css ?? []) appletUikitCss.add(cssFile)
              for (const child of chunk.imports ?? []) {
                if (!seenApplet.has(child)) appletQueue.push(child)
              }
            }
          }
          for (const [entryKey, entryMeta] of Object.entries(manifest)) {
            if (!entryMeta?.isEntry) continue
            const visited = new Set<string>()
            const queue = [...(entryMeta.imports ?? [])]
            while (queue.length > 0) {
              const depKey = queue.shift()!
              if (visited.has(depKey)) continue
              visited.add(depKey)
              const dep = manifest[depKey]
              if (!dep) continue
              const chunkName = dep.name ?? ''
              if (lazyVizChunks.has(chunkName)) {
                throw new Error(
                  `Lazy visualization chunk "${chunkName}" (${dep.file ?? depKey}) is statically imported by entry "${entryKey}". Keep visualization engines behind dynamic import().`
                )
              }
              for (const child of dep.imports ?? []) {
                if (!visited.has(child)) queue.push(child)
              }
            }
            if (appletUikitCss.size > 0 && !entryMeta.name?.startsWith('applet-')) {
              const fullVisited = new Set<string>()
              const fullQueue = [entryKey]
              while (fullQueue.length > 0) {
                const key = fullQueue.shift()!
                if (fullVisited.has(key)) continue
                fullVisited.add(key)
                const chunk = manifest[key]
                if (!chunk) continue
                for (const cssFile of chunk.css ?? []) {
                  if (appletUikitCss.has(cssFile)) {
                    throw new Error(
                      `Standalone Applet uikit CSS "${cssFile}" leaked into host entry "${entryKey}" via "${key}". Keep CSS modules out of shared JS manualChunks.`
                    )
                  }
                }
                for (const child of [...(chunk.imports ?? []), ...(chunk.dynamicImports ?? [])]) {
                  if (!fullVisited.has(child)) fullQueue.push(child)
                }
              }
            }
          }
        }
        // Plug.Static serves these sidecars without changing Vite's hashed files or manifest.
        for (const file of readdirSync(outputPath, { recursive: true, encoding: 'utf8' })) {
          if (!/\.(css|js|json|map|svg|wasm)$/.test(file)) continue
          const sourcePath = path.join(outputPath, file)
          const source = readFileSync(sourcePath)
          const compressed = gzipSync(source)
          if (compressed.byteLength < source.byteLength) writeFileSync(`${sourcePath}.gz`, compressed)
        }
      }
    },
    phoenixShellPlugin()
  ],
  optimizeDeps: {
    entries: Object.values(entries),
    include: [
      '@ankole/uikit > @antv/g6',
      '@ankole/uikit > @antv/g2',
      '@ankole/uikit > @antv/g-svg',
      '@ankole/uikit > @antv/infographic',
      '@ankole/uikit > lightweight-charts'
    ]
  },
  publicDir: false,
  resolve: { alias: [{ find: '@ankole/locales', replacement: localeDirectory }, ...editionAssetAliases()] },
  root: dirname,
  server: {
    fs: { allow: edition === 'saas' ? [repositoryRoot, artifactRoot, internalsRoot] : [repositoryRoot, artifactRoot] },
    cors: {
      origin: [
        `http://localhost:${phoenixPort}`,
        `http://127.0.0.1:${phoenixPort}`,
        new RegExp(`^http://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)?ankole\\.localhost:${phoenixPort}$`),
        ...saasOrigins
      ]
    },
    host: '127.0.0.1',
    hmr: {
      overlay: true
    },
    origin: devServerOrigin,
    port: 3035,
    strictPort: true,
    ws: {
      clientPort: 3035,
      host: '127.0.0.1',
      port: 3035,
      protocol: 'ws'
    }
  },
  build: {
    assetsDir: '.',
    chunkSizeWarningLimit: 500,
    cssCodeSplit: true,
    cssTarget: ['chrome132', 'firefox160', 'safari18'],
    emptyOutDir: true,
    manifest: 'manifest.json',
    outDir: outputPath,
    sourcemap: true,
    target: ['chrome132', 'firefox160', 'safari18'],
    rolldownOptions: {
      preserveEntrySignatures: 'strict',
      input: entries,
      output: {
        assetFileNames: info => {
          const name = info.names[0] ?? ''
          if (/\.(woff2?|ttf|otf)$/i.test(name)) return 'fonts/[name]-[hash][extname]'
          if (/\.(png|jpe?g|gif|svg|webp|avif)$/i.test(name)) return 'media/[name]-[hash][extname]'
          if (/\.css$/i.test(name)) return 'css/[name]-[hash][extname]'
          return '[name]-[hash][extname]'
        },
        chunkFileNames: 'js/[name]-[hash].js',
        entryFileNames: 'js/[name]-[hash].js',
        codeSplitting: {
          // Shared dependencies must not pull applet-only code into every entry.
          groups: [{ name: manualChunks, debugName: 'vendor-packages', entriesAware: true }]
        }
      }
    }
  },
  clearScreen: command !== 'serve'
}))
