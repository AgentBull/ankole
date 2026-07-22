import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

/**
 * Regenerates the RuntimeFabric TypeScript codec from the kernel protos, or
 * verifies the committed output with `--check`.
 *
 * `envelope.proto` and `rpc.proto` are the only structural declarations of
 * the fabric protocol. Rust (prost-build, envelope only) and Elixir (protox)
 * derive their codecs at compile time; only TypeScript checks generated code
 * in. This script's `--check` mode does a full byte-level regeneration diff.
 */
const packageRoot = path.resolve(import.meta.dir, '..')
const generatedDir = path.join(packageRoot, 'src', 'fabric', 'generated')
const protoNames = ['envelope', 'rpc'] as const

function generatedRelative(name: (typeof protoNames)[number]): string {
  return path.join('src', 'fabric', 'generated', 'ankole', 'runtime_fabric', 'v1', `${name}_pb.ts`)
}

function normalizeGeneratedFiles(root: string): void {
  for (const name of protoNames) {
    const generatedPath = path.join(root, generatedRelative(name))
    const generated = readFileSync(generatedPath, 'utf8')
    writeFileSync(generatedPath, generated.replace(/\n+$/u, '\n'))
  }
}

// `--output` overrides the template's `out:` directory entirely; the generated
// package path (ankole/runtime_fabric/v1) is appended by protoc-gen-es.
function generate(outDir?: string): void {
  const args = ['buf', 'generate', '--template', 'scripts/buf.gen.yaml']
  if (outDir) args.push('--output', outDir)

  const result = spawnSync('bunx', args, {
    cwd: packageRoot,
    stdio: 'inherit'
  })
  if (result.status !== 0) {
    throw new Error(`buf generate failed with status ${result.status}`)
  }
}

if (import.meta.main) {
  if (process.argv.includes('--check')) {
    const scratch = mkdtempSync(path.join(tmpdir(), 'ankole-fabric-proto-'))
    try {
      generate(scratch)
      normalizeGeneratedFiles(scratch)
      for (const name of protoNames) {
        const relativePath = generatedRelative(name)
        const fresh = readFileSync(path.join(scratch, relativePath), 'utf8')
        const committed = readFileSync(path.join(packageRoot, relativePath), 'utf8')
        if (fresh !== committed) {
          console.error(`generated ${name}_pb.ts is stale; run \`bun run gen:proto\``)
          process.exit(1)
        }
      }
      console.warn('generated fabric proto output is up to date')
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  } else {
    rmSync(generatedDir, { recursive: true, force: true })
    generate()
    normalizeGeneratedFiles(packageRoot)
    console.warn(`wrote ${path.relative(packageRoot, generatedDir)}`)
  }
}
