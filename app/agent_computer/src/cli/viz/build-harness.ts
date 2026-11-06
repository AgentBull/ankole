import type { BunPlugin } from 'bun'
import { mkdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

/**
 * Works around a Bun 1.4 CJS scope-hoisting edge case in `pdfast` (a transitive
 * dependency of `@antv/g2`) where `var self = module.exports;` references an
 * eliminated `exports_src` symbol when `module.exports.*` properties are hoisted.
 */
const pdfastCjsInteropPlugin: BunPlugin = {
  name: 'ankole-viz-pdfast-cjs-interop',
  setup(build) {
    build.onLoad({ filter: /pdfast[\\/]+src[\\/]+index\.js$/ }, args => {
      const original = readFileSync(args.path, 'utf8')
      const patched = original.replace(
        'var self = module.exports;',
        'var self = { getUnifiedMinMax: function(a, o) { return module.exports.getUnifiedMinMax(a, o); }, getUnifiedMinMaxMulti: function(a, o) { return module.exports.getUnifiedMinMaxMulti(a, o); } };'
      )
      return { contents: patched, loader: 'js' }
    })
  }
}

export async function buildVizHarnessBundle(outdir: string): Promise<string> {
  const resolvedOutdir = resolve(outdir)
  mkdirSync(resolvedOutdir, { recursive: true })
  const entrypoint = join(import.meta.dir, 'harness-entry.ts')

  const result = await Bun.build({
    entrypoints: [entrypoint],
    outdir: resolvedOutdir,
    target: 'browser',
    format: 'esm',
    minify: false,
    plugins: [pdfastCjsInteropPlugin]
  })

  if (!result.success) {
    const messages = result.logs.map(log => log.message || String(log)).join('; ')
    throw new Error(`Failed to bundle ankole-viz browser harness: ${messages || 'unknown build error'}`)
  }

  return join(resolvedOutdir, 'harness-entry.js')
}

if (import.meta.main) {
  const outdir = process.argv[2]
  if (!outdir) {
    process.stderr.write('Usage: bun build-harness.ts <outdir>\n')
    process.exit(1)
  }
  await buildVizHarnessBundle(outdir)
}
