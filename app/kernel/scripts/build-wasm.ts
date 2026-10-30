import { spawnSync } from 'node:child_process'
import { readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { gzipSync } from 'node:zlib'

import { kernelRoot, runCargo } from './cargo'

// The CLI and the `wasm-bindgen` crate share one ABI, so this version must equal the one that
// `spreadsheet-wasm/Cargo.toml` pins.
const WASM_BINDGEN_VERSION = '0.2.130'
// The WebAssembly features Rust enables by default for wasm32-unknown-unknown.
const WASM_FEATURES = [
  '--enable-bulk-memory',
  '--enable-mutable-globals',
  '--enable-nontrapping-float-to-int',
  '--enable-sign-ext',
  '--enable-reference-types',
  '--enable-multivalue'
]

const toolsRoot = join(kernelRoot, 'target/wasm-tools')
const outDir = join(kernelRoot, 'dist/spreadsheet-wasm')
const built = join(kernelRoot, 'target/wasm32-unknown-unknown/wasm-release/ankole_spreadsheet_wasm.wasm')
const bindgenWasm = join(outDir, 'ankole_spreadsheet_wasm_bg.wasm')

function run(command: string, args: string[]): void {
  const result = spawnSync(command, args, { cwd: kernelRoot, stdio: 'inherit' })
  if (result.error) throw new Error(`${command} failed to start: ${result.error.message}`)
  if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} exited with ${result.status}`)
}

function installedVersion(binary: string): string | null {
  const result = spawnSync(binary, ['--version'], { encoding: 'utf8' })
  return result.status === 0 ? (result.stdout.trim().split(/\s+/).pop() ?? null) : null
}

/** Installs the pinned wasm-bindgen CLI into the kernel's target directory once. */
function wasmBindgen(): string {
  const binary = join(toolsRoot, 'bin', 'wasm-bindgen')
  if (installedVersion(binary) !== WASM_BINDGEN_VERSION) {
    runCargo(['install', 'wasm-bindgen-cli', '--version', `=${WASM_BINDGEN_VERSION}`, '--locked', '--root', toolsRoot])
  }
  return binary
}

/** Loads the generated module and runs one edit, so a broken artifact fails the build. */
async function smokeCheck(): Promise<void> {
  const module = await import(join(outDir, 'ankole_spreadsheet_wasm.js'))
  module.initSync({ module: readFileSync(bindgenWasm) })
  const sheet = module.Spreadsheet.create_blank('Smoke')
  sheet.apply(JSON.stringify({ type: 'cell.set', sheet_id: 1, cell: 'A1', input: '=1+2' }))
  const viewport = JSON.parse(sheet.viewport(1, 0, 0, 0, 0))
  if (viewport.cells[0]?.text !== '3') throw new Error(`the WebAssembly smoke check read ${JSON.stringify(viewport)}`)
  const reopened = module.Spreadsheet.open(sheet.export_xlsx(), '[]')
  if (reopened.cell_input(1, 'A1') !== '=1+2') throw new Error('the WebAssembly smoke check lost the formula on export')
}

runCargo(['build', '-p', 'ankole_spreadsheet_wasm', '--target', 'wasm32-unknown-unknown', '--profile', 'wasm-release'])
rmSync(outDir, { recursive: true, force: true })
run(wasmBindgen(), [built, '--target', 'web', '--out-dir', outDir])
const wasmOpt = Bun.which('wasm-opt')
if (wasmOpt) {
  run(wasmOpt, ['-Oz', ...WASM_FEATURES, bindgenWasm, '-o', bindgenWasm])
} else {
  console.warn(
    'WARN: wasm-opt is not on PATH; the module is not post-optimized. Install binaryen to shrink it further.'
  )
}
await smokeCheck()

const bytes = readFileSync(bindgenWasm)
const kib = (n: number) => `${(n / 1024).toFixed(1)} KiB`
process.stdout.write(`${bindgenWasm}: ${kib(bytes.length)} raw, ${kib(gzipSync(bytes, { level: 9 }).length)} gzip\n`)
