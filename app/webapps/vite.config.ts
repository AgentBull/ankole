import path from 'node:path'
import { fileURLToPath } from 'node:url'
import babel from '@rolldown/plugin-babel'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import { parse as parseToml } from 'smol-toml'
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

function manualChunks(moduleID: string): string | undefined {
  if (!moduleID.includes('/node_modules/')) return undefined
  if (moduleID.includes('/react/') || moduleID.includes('/react-dom/') || moduleID.includes('/scheduler/')) {
    return 'vendor-react'
  }
  if (moduleID.includes('/react-router/')) return 'vendor-router'

  if (
    moduleID.includes('/@tanstack/query-core/') ||
    moduleID.includes('/@tanstack/react-query/') ||
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

function tomlPlugin(): Plugin {
  return {
    name: 'ankole-toml',
    transform(code, id) {
      if (!id.endsWith('.toml')) return

      return {
        code: `export default ${JSON.stringify(parseToml(code))}`,
        map: null
      }
    }
  }
}

export default defineConfig(
  ({ command }): UserConfig => ({
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
    clearScreen: command === 'serve' ? false : true
  })
)
