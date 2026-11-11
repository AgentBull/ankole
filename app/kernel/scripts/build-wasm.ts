import { spawnSync } from 'node:child_process'
import { copyFileSync, readFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { gzipSync } from 'node:zlib'

import { kernelRoot, runCargo } from './cargo'

// The CLI and the `wasm-bindgen` crate share one ABI, so this version must equal the one that
// `spreadsheet-wasm`, `presentation-wasm`, and `word-wasm` pin in their `Cargo.toml` manifests.
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

type WasmTarget = {
  crateName: string
  dirName: string
  smokeCheck: (module: Record<string, any>) => void
}

const TARGETS: WasmTarget[] = [
  {
    crateName: 'ankole_spreadsheet_wasm',
    dirName: 'spreadsheet-wasm',
    smokeCheck: module => {
      const sheet = module.Spreadsheet.create_blank('Smoke')
      sheet.apply(JSON.stringify({ type: 'cell.set', sheet_id: 1, cell: 'A1', input: '=1+2' }))
      const viewport = JSON.parse(sheet.viewport(1, 0, 0, 0, 0))
      if (viewport.cells[0]?.text !== '3') {
        throw new Error(`spreadsheet WebAssembly smoke check read ${JSON.stringify(viewport)}`)
      }
      const reopened = module.Spreadsheet.open(sheet.export_xlsx(), '[]')
      if (reopened.cell_input(1, 'A1') !== '=1+2') {
        throw new Error('spreadsheet WebAssembly smoke check lost the formula on export')
      }
    }
  },
  {
    crateName: 'ankole_presentation_wasm',
    dirName: 'presentation-wasm',
    smokeCheck: module => {
      const editor = module.PresentationEditor.create_blank('Smoke')
      const slides = JSON.parse(editor.slides_info())
      if (!Array.isArray(slides) || slides.length < 1) {
        throw new Error(`presentation WebAssembly smoke check read ${JSON.stringify(slides)}`)
      }
      const reopened = module.PresentationEditor.open(editor.export_pptx(), '[]')
      if (JSON.parse(reopened.slides_info()).length !== slides.length) {
        throw new Error('presentation WebAssembly smoke check lost slides on export')
      }
    }
  },
  {
    crateName: 'ankole_word_wasm',
    dirName: 'word-wasm',
    smokeCheck: module => {
      const editor = module.WordEditor.create_blank('Smoke')
      editor.insert_text('Smoke paragraph')
      const opJson = editor.commit_local_step()
      if (typeof opJson !== 'string' || !opJson.includes('blocks.splice')) {
        throw new Error(`word WebAssembly smoke check derived ${String(opJson)}`)
      }
      const reopened = module.WordEditor.open(editor.export_docx(), '[]')
      const matches = JSON.parse(reopened.find('Smoke', true))
      if (!Array.isArray(matches) || matches.length !== 1) {
        throw new Error(`word WebAssembly smoke check find returned ${JSON.stringify(matches)}`)
      }
    }
  }
]

const toolsRoot = join(kernelRoot, 'target/wasm-tools')

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

runCargo([
  'build',
  ...TARGETS.flatMap(target => ['-p', target.crateName]),
  '--target',
  'wasm32-unknown-unknown',
  '--profile',
  'wasm-release'
])

const bindgen = wasmBindgen()
const wasmOpt = Bun.which('wasm-opt')
if (!wasmOpt) {
  console.warn(
    'WARN: wasm-opt is not on PATH; modules are not post-optimized. Install binaryen to shrink them further.'
  )
}

const kib = (n: number) => `${(n / 1024).toFixed(1)} KiB`

for (const target of TARGETS) {
  const outDir = join(kernelRoot, 'dist', target.dirName)
  const built = join(kernelRoot, 'target/wasm32-unknown-unknown/wasm-release', `${target.crateName}.wasm`)
  const bindgenWasm = join(outDir, `${target.crateName}_bg.wasm`)
  const declarations = `${target.crateName}.d.ts`

  rmSync(outDir, { recursive: true, force: true })
  run(bindgen, [built, '--target', 'web', '--out-dir', outDir])
  if (wasmOpt) {
    run(wasmOpt, ['-Oz', ...WASM_FEATURES, bindgenWasm, '-o', bindgenWasm])
  }

  const module = (await import(join(outDir, `${target.crateName}.js`))) as Record<string, any>
  module.initSync({ module: readFileSync(bindgenWasm) })
  target.smokeCheck(module)

  // The declarations live in git as well, so that type checks of the webapps pass on machines
  // without a Rust toolchain. Every build refreshes them.
  copyFileSync(join(outDir, declarations), join(kernelRoot, target.dirName, declarations))

  const bytes = readFileSync(bindgenWasm)
  process.stdout.write(`${bindgenWasm}: ${kib(bytes.length)} raw, ${kib(gzipSync(bytes, { level: 9 }).length)} gzip\n`)
}
