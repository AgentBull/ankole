import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
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
 * in, so a sidecar hash pins the committed output to the proto contents, the
 * buf configuration, and the pinned generator versions. The unit suite
 * asserts the sidecar, and this script's `--check` mode does a full
 * byte-level regeneration diff for local use and hooks.
 */
const packageRoot = path.resolve(import.meta.dir, '..')
const generatedDir = path.join(packageRoot, 'src', 'fabric', 'generated')
const sidecarPath = path.join(generatedDir, 'envelope.proto.hash')
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

export function generationFingerprint(): string {
  const hash = createHash('sha256')
  for (const name of protoNames) {
    hash.update(
      readFileSync(path.join(packageRoot, '..', 'kernel', 'proto', 'ankole', 'runtime_fabric', 'v1', `${name}.proto`))
    )
  }
  const bufGenConfig = readFileSync(path.join(packageRoot, 'scripts', 'buf.gen.yaml'))
  const packageJSON = JSON.parse(readFileSync(path.join(packageRoot, 'package.json'), 'utf8')) as {
    dependencies: Record<string, string>
    devDependencies: Record<string, string>
  }
  const toolVersions = [
    `@bufbuild/protobuf@${packageJSON.dependencies['@bufbuild/protobuf']}`,
    `@bufbuild/buf@${packageJSON.devDependencies['@bufbuild/buf']}`,
    `@bufbuild/protoc-gen-es@${packageJSON.devDependencies['@bufbuild/protoc-gen-es']}`
  ].join('\n')

  return hash.update(bufGenConfig).update(toolVersions).digest('hex')
}

export function committedFingerprint(): string {
  return readFileSync(sidecarPath, 'utf8').trim()
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
      if (committedFingerprint() !== generationFingerprint()) {
        console.error('envelope.proto.hash sidecar is stale; run `bun run gen:proto`')
        process.exit(1)
      }
      console.warn('generated fabric proto output is up to date')
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  } else {
    rmSync(generatedDir, { recursive: true, force: true })
    generate()
    normalizeGeneratedFiles(packageRoot)
    writeFileSync(sidecarPath, `${generationFingerprint()}\n`)
    console.warn(`wrote ${path.relative(packageRoot, generatedDir)} and refreshed the sidecar hash`)
  }
}
