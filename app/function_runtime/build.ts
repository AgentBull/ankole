import { resolve } from 'node:path'

const compatibility = resolve(import.meta.dir, 'main/node_crypto.ts')
const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, 'main/index.ts')],
  target: 'node',
  define: { global: 'globalThis' },
  banner: "import process from 'node:process'; import { Buffer } from 'node:buffer';",
  outdir: process.argv[2] ?? resolve(import.meta.dir, 'dist'),
  plugins: [
    {
      name: 'edge-runtime-node-crypto',
      setup(build) {
        build.onResolve({ filter: /^jsonc-parser$/ }, args => ({
          path: Bun.resolveSync('jsonc-parser/lib/esm/main.js', args.resolveDir)
        }))
        build.onResolve({ filter: /^node:crypto$/ }, args =>
          args.importer === compatibility ? { path: 'node:crypto', external: true } : { path: compatibility }
        )
      }
    }
  ]
})
if (!result.success) {
  for (const message of result.logs) console.error(message)
  process.exit(1)
}
