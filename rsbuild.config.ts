import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import toml from "@iarna/toml"
import { defineConfig } from "@rsbuild/core"
import { pluginReact } from "@rsbuild/plugin-react"
import tailwindcss from "@tailwindcss/postcss"

const appRoot = dirname(fileURLToPath(import.meta.url))
const webuiRoot = resolve(appRoot, "webui/src")
const mixEnv = process.env.MIX_ENV || "dev"
const phoenixPort = parsePort(process.env.PORT || "4000", "PORT")
const rsbuildPort = parsePort(process.env.RSBUILD_PORT || "5173", "RSBUILD_PORT")
const rsbuildHost = "127.0.0.1"
const rsbuildOrigin = `http://${rsbuildHost}:${rsbuildPort}`
const rsbuildManifestWatchIgnore =
  /[\\/](?:\.git|node_modules)[\\/]|[\\/]priv[\\/]static[\\/]\.rsbuild[\\/]manifest\.json$/

function parsePort(raw, envVar) {
  const port = Number.parseInt(raw, 10)

  if (Number.isNaN(port) || String(port) !== raw || port < 1 || port > 65535) {
    throw new Error(`Invalid ${envVar}: ${raw}`)
  }

  return port
}

function localOrigins(port) {
  return [`http://localhost:${port}`, `http://127.0.0.1:${port}`]
}

function phoenixPlugin() {
  return {
    name: "bullx-phoenix-rsbuild",
    setup(api) {
      api.onBeforeStartDevServer(() => {
        process.stdin.resume()
      })
    },
  }
}

function tomlPlugin() {
  return {
    name: "bullx-toml",
    setup(api) {
      api.transform({ test: /\.toml$/ }, ({ code }) => ({
        code: `export default ${JSON.stringify(toml.parse(code))}`,
        map: null,
      }))
    },
  }
}

export default defineConfig({
  root: appRoot,
  source: {
    entry: {
      app: {
        import: ["./webui/src/app.tsx", "./webui/src/globals.css"],
        html: false,
      },
      "web-console": {
        import: ["./webui/src/apps/web-console/main.tsx", "./webui/src/globals.css"],
        html: false,
      },
    },
    define: {
      "process.env.RSTEST": false,
    },
  },
  server: {
    host: rsbuildHost,
    port: rsbuildPort,
    strictPort: true,
    cors: {
      origin: localOrigins(phoenixPort),
    },
  },
  dev: {
    assetPrefix: `${rsbuildOrigin}/`,
    client: {
      host: rsbuildHost,
      port: rsbuildPort,
      protocol: "ws",
    },
    writeToDisk: file => file.endsWith(".rsbuild/manifest.json"),
    watchFiles: {
      paths: resolve(appRoot, "priv/locales/client/*.toml"),
      type: "reload-page",
    },
  },
  output: {
    cleanDistPath: false,
    distPath: {
      root: resolve(appRoot, "priv/static"),
      js: "js",
      jsAsync: "js",
      css: "css",
      cssAsync: "css",
      svg: "assets",
      font: "assets",
      image: "assets",
      media: "assets",
      assets: "assets",
    },
    manifest: {
      filename: ".rsbuild/manifest.json",
      prefix: false,
    },
  },
  resolve: {
    alias: {
      "@": webuiRoot,
      "@locales": resolve(appRoot, "priv/locales/client"),
    },
  },
  tools: {
    rspack(config) {
      config.watchOptions = {
        ...config.watchOptions,
        ignored: rsbuildManifestWatchIgnore,
      }
    },
    postcss(_options, { addPlugins }) {
      addPlugins(tailwindcss())
    },
  },
  plugins: [pluginReact(), phoenixPlugin(), tomlPlugin()],
})
