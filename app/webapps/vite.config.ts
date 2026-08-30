import path from 'node:path'
import { fileURLToPath } from 'node:url'
import babel from '@rolldown/plugin-babel'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import { defineConfig, type Plugin, type UserConfig, type ViteDevServer } from 'vite'

const filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(filename)
const outputPath = path.resolve(dirname, '../control_plane/priv/static/assets')
const devServerOrigin = 'http://127.0.0.1:3035'
const phoenixShutdownGraceMs = 2_000
const phoenixRestartGuardKey = Symbol.for('ankole.vite.phoenix-restart-guard')
let phoenixShutdownGuardInstalled = false

const entries = {
  auth: path.resolve(dirname, 'entrypoints/auth.tsx'),
  console: path.resolve(dirname, 'entrypoints/console.tsx'),
  setup: path.resolve(dirname, 'entrypoints/setup.tsx')
}

// The Markdown rendering pipeline behind `console/markdown-renderer.tsx`.
// These packages have no consumer outside that dynamic import, so grouping
// them cannot pull the chunk into an eager entry. The list is hand-frozen:
// after a react-markdown upgrade, rebuild it from the dependency closure
// (`bun pm ls --all` under the react-markdown subtree) — a package that
// falls off the list only lands in `vendor-utilities`, so the failure mode
// is bundle-size drift, not breakage.
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
  if (!moduleID.includes('/node_modules/')) return undefined
  if (moduleID.includes('/react/') || moduleID.includes('/react-dom/') || moduleID.includes('/scheduler/')) {
    return 'vendor-react'
  }
  if (moduleID.includes('/react-router/')) return 'vendor-router'

  // Only a dynamic import reaches the zxcvbn dictionaries, so a chunk of
  // their own loads lazily. The catch-all would fold their hundreds of
  // kilobytes into the eagerly loaded utilities bundle.
  if (moduleID.includes('/@zxcvbn-ts/')) return 'vendor-zxcvbn'

  // The same reasoning covers the other dynamic-import-only heavyweights:
  // the agents editor's transliteration table, the JSON tree editor, and the
  // Markdown pipeline.
  if (moduleID.includes('/any-ascii/')) return 'vendor-transliteration'
  if (moduleID.includes('/json-edit-react/')) return 'vendor-json-editor'
  const packageName = nodeModulePackageName(moduleID)
  if (
    packageName &&
    (markdownPipelinePackages.has(packageName) ||
      markdownPipelinePrefixes.some(prefix => packageName.startsWith(prefix)))
  ) {
    return 'vendor-markdown'
  }

  if (
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
    moduleID.includes('/@formisch/react/') ||
    moduleID.includes('/@remixicon/react/') ||
    moduleID.includes('/valibot/')
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
    },
    handleHotUpdate({ file, modules }) {
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

function tomlPlugin(): Plugin {
  return {
    name: 'ankole-toml',
    transform(code, id) {
      if (!id.endsWith('.toml')) return

      return {
        code: `export default ${JSON.stringify(Bun.TOML.parse(code))}`,
        map: null
      }
    }
  }
}

export default defineConfig(({ command }): UserConfig => ({
  base: command === 'build' ? '/assets/' : '/',
  plugins: [
    tomlPlugin(),
    react(),
    babel({
      presets: [reactCompilerPreset()]
    }),
    phoenixShellPlugin()
  ],
  publicDir: false,
  root: dirname,
  server: {
    cors: {
      origin: ['http://localhost:4000', 'http://127.0.0.1:4000']
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
    emptyOutDir: true,
    manifest: 'manifest.json',
    outDir: outputPath,
    sourcemap: true,
    rolldownOptions: {
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
        manualChunks
      }
    }
  },
  clearScreen: command !== 'serve'
}))
