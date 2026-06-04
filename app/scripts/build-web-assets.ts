import tailwind from 'bun-plugin-tailwind'
import { rm, writeFile } from 'node:fs/promises'
import path from 'node:path'

const appRoot = path.resolve(import.meta.dir, '..')
const outdir = path.join(appRoot, 'public/assets')
const entrypoints = [
  path.join(appRoot, 'webui/src/entries/setup.tsx'),
  path.join(appRoot, 'webui/src/entries/sessions.tsx'),
  path.join(appRoot, 'webui/src/entries/console.tsx')
]

await rm(outdir, { recursive: true, force: true })

const result = await Bun.build({
  entrypoints,
  outdir,
  publicPath: '/assets/',
  target: 'browser',
  format: 'esm',
  splitting: true,
  sourcemap: 'external',
  naming: {
    entry: '[name]-entry.[ext]',
    chunk: '[name]-[hash].[ext]',
    asset: '[name].[ext]'
  },
  plugins: [tailwind]
})

if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}

const buildId = Date.now().toString(36)
const manifest = {
  setup: assetEntry('setup'),
  sessions: assetEntry('sessions'),
  console: assetEntry('console')
}

await writeFile(path.join(outdir, 'manifest.json'), JSON.stringify(manifest, null, 2))

function assetEntry(name: string) {
  const js = versioned(`/assets/${name}-entry.js`)
  const cssOutput =
    result.outputs.find(output => path.basename(output.path) === `${name}-entry.css`) ??
    result.outputs.find(output => output.path.endsWith('.css'))

  return {
    js,
    ...(cssOutput ? { css: versioned(`/assets/${path.basename(cssOutput.path)}`) } : {})
  }
}

function versioned(assetPath: string): string {
  return `${assetPath}?v=${buildId}`
}
