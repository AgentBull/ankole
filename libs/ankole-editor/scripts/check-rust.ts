/** Compare generated, continuous edit batches with the production Rust codec. */
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import fc from 'fast-check'
import { printXml } from '../src/document/xml'
import { page } from '../test/arbitrary'
import { editBatches, editChain } from './rust-corpus'

const seed = process.env.FC_SEED ? Number(process.env.FC_SEED) : 20261018
const directory = mkdtempSync(join(tmpdir(), 'ankole-page-rust-'))
const path = join(directory, 'cases.json')
const cases = fc
  .sample(fc.tuple(page, editBatches), { seed, numRuns: 100 })
  .map(([tree, batches], index) => editChain(`property-${index}-seed-${seed}`, printXml(tree), batches))
writeFileSync(path, JSON.stringify(cases))
const result = Bun.spawnSync(
  [
    'cargo',
    'test',
    '--manifest-path',
    'app/kernel/Cargo.toml',
    '--no-default-features',
    'generated_continuous_batches',
    '--',
    '--ignored',
    '--nocapture'
  ],
  {
    cwd: fileURLToPath(new URL('../../../', import.meta.url)),
    env: { ...process.env, ANKOLE_PAGE_PROPERTY_CASES: path },
    stdout: 'inherit',
    stderr: 'inherit'
  }
)
if (result.exitCode) {
  console.error(`Failed corpus retained at ${path}; reproduce with FC_SEED=${seed}`)
  process.exit(result.exitCode)
}
rmSync(directory, { recursive: true })
console.warn(`Rust agrees with ${cases.length} generated page/edit chains (seed ${seed}).`)
