import path from 'node:path'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin, type UserConfig } from 'vite'

const filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(filename)
const outputPath = path.resolve(dirname, '../control_plane/priv/static/assets')
const devServerOrigin = 'http://127.0.0.1:3035'

const entries = {
  auth: path.resolve(dirname, 'entrypoints/auth.tsx'),
  console: path.resolve(dirname, 'entrypoints/console.tsx'),
  setup: path.resolve(dirname, 'entrypoints/setup.tsx')
}

function manualChunks(moduleId: string): string | undefined {
  if (!moduleId.includes('/node_modules/')) return undefined
  if (moduleId.includes('/react/') || moduleId.includes('/react-dom/') || moduleId.includes('/scheduler/')) return 'vendor-react'
  if (moduleId.includes('/react-router/')) return 'vendor-router'

  if (
    moduleId.includes('/@tanstack/query-core/') ||
    moduleId.includes('/@tanstack/react-query/') ||
    moduleId.includes('/i18next/') ||
    moduleId.includes('/react-i18next/') ||
    moduleId.includes('/html-parse-stringify/')
  ) {
    return 'vendor-data'
  }

  if (
    moduleId.includes('/@base-ui/') ||
    moduleId.includes('/@floating-ui/') ||
    moduleId.includes('/@formisch/react/') ||
    moduleId.includes('/@remixicon/react/') ||
    moduleId.includes('/valibot/')
  ) {
    return 'vendor-setup-ui'
  }

  return 'vendor-utilities'
}

function phoenixShellPlugin(): Plugin {
  return {
    name: 'ankole-phoenix-shell',
    configureServer() {
      // Phoenix starts Vite as a watcher process. Keep stdin active so Vite can
      // notice when the parent port closes and exit instead of leaving the port
      // occupied after mix phx.server stops.
      process.stdin.resume()
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

export default defineConfig(({ command }): UserConfig => ({
  base: command === 'build' ? '/assets/' : '/',
  plugins: [react(), phoenixShellPlugin()],
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
  clearScreen: command === 'serve' ? false : true
}))
