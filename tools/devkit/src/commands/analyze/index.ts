import { Crust } from '@crustjs/core'
import { DEFAULT_TOPOLOGY_SCOPE, TOPOLOGY_GATED_SCOPES, TOPOLOGY_SCOPES } from './config'
import { runCycles } from './cycles'
import { runDuplicates } from './duplicates'
import { runSmells } from './smells'
import { runTopology } from './topology'
import type { CheckResult, ExitCode } from './types'
import { runUnused } from './unused'

const jsonFlag = {
  json: { type: 'boolean', description: 'Emit machine-readable JSON.', default: false }
} as const

function emit(result: CheckResult, json: boolean): void {
  if (json) {
    process.stdout.write(`${JSON.stringify(result.json, null, 2)}\n`)
  } else {
    process.stdout.write(`${result.human}\n`)
  }
  process.exitCode = result.exitCode
}

/**
 * Runs every gate plus the report-only topology scope and aggregates the exit code.
 */
async function runAll(options: { json: boolean; skip?: string }): Promise<void> {
  const skip = new Set(
    (options.skip ?? '')
      .split(',')
      .map(value => value.trim())
      .filter(Boolean)
  )

  const gates: Array<{ name: string; run: () => CheckResult | Promise<CheckResult> }> = [
    { name: 'smells', run: () => runSmells() },
    { name: 'unused', run: () => runUnused() },
    { name: 'duplicates', run: () => runDuplicates() },
    { name: 'cycles', run: () => runCycles() },
    // Internal module surfaces must not export what nothing consumes.
    ...TOPOLOGY_GATED_SCOPES.map(scope => ({
      name: `topology:${scope}`,
      run: () => runTopology({ scope, report: 'unused-public-surface' })
    }))
  ]

  const results: Array<{ name: string; result: CheckResult; gate: boolean }> = []
  for (const gate of gates) {
    if (skip.has(gate.name)) {
      continue
    }
    results.push({ name: gate.name, result: await gate.run(), gate: true })
  }
  if (!skip.has('topology')) {
    // The default topology report is informational. Only selected internal
    // unused-surface reports above are gates because broad topology can be noisy.
    results.push({ name: 'topology', result: runTopology(), gate: false })
  }

  const exitCode = results
    .filter(entry => entry.gate)
    .reduce<ExitCode>((max, entry) => (entry.result.exitCode > max ? entry.result.exitCode : max), 0)

  if (options.json) {
    process.stdout.write(
      `${JSON.stringify(
        {
          check: 'all',
          ok: exitCode === 0,
          exitCode,
          results: Object.fromEntries(results.map(entry => [entry.name, entry.result.json]))
        },
        null,
        2
      )}\n`
    )
    process.exitCode = exitCode
    return
  }

  // Detail only for failing gates; topology stays report-only in the table.
  for (const entry of results) {
    if (entry.gate && !entry.result.ok) {
      process.stdout.write(`${entry.result.human}\n\n`)
    }
  }
  process.stdout.write('analyze summary\n')
  for (const entry of results) {
    process.stdout.write(`  ${entry.name.padEnd(12)} ${entry.result.summary}\n`)
  }
  process.exitCode = exitCode
}

export function analyzeCommand(): Crust {
  return new Crust('analyze')
    .meta({
      aliases: ['check'],
      description: 'Static architecture guards for the Ankole monorepo.'
    })
    .command('smells', cmd =>
      cmd
        .meta({ description: 'Boundary / architecture-smell gate.' })
        .flags({ ...jsonFlag })
        .run(({ flags }) => {
          emit(runSmells({ json: flags.json }), flags.json)
        })
    )
    .command('unused', cmd =>
      cmd
        .meta({ description: 'Knip unused-file gate vs the owner/reason allowlist.' })
        .flags({ ...jsonFlag })
        .run(async ({ flags }) => {
          emit(await runUnused({ json: flags.json }), flags.json)
        })
    )
    .command('duplicates', cmd =>
      cmd
        .meta({ aliases: ['dup'], description: 'jscpd cross-module duplication gate.' })
        .flags({
          ...jsonFlag,
          'coverage-only': {
            type: 'boolean',
            description: 'Only assert every tracked source file is inside a scan target.',
            default: false
          },
          'min-lines': { type: 'number', description: 'Override the min-lines threshold.' },
          'min-tokens': { type: 'number', description: 'Override the min-tokens threshold.' }
        })
        .run(async ({ flags }) => {
          emit(
            await runDuplicates({
              json: flags.json,
              coverageOnly: flags['coverage-only'],
              minLines: flags['min-lines'],
              minTokens: flags['min-tokens']
            }),
            flags.json
          )
        })
    )
    .command('cycles', cmd =>
      cmd
        .meta({ description: 'Runtime-value import-cycle gate, target = 0.' })
        .flags({
          ...jsonFlag,
          'include-tests': { type: 'boolean', description: 'Include test files.', default: false }
        })
        .run(({ flags }) => {
          emit(runCycles({ json: flags.json, includeTests: flags['include-tests'] }), flags.json)
        })
    )
    .command('topology', cmd =>
      cmd
        .meta({ description: 'Public-surface usage reports; unused-public-surface gates internal scopes.' })
        .flags({
          ...jsonFlag,
          scope: {
            type: 'string',
            description: `Named scope: ${Object.keys(TOPOLOGY_SCOPES).join(' | ')}.`,
            default: DEFAULT_TOPOLOGY_SCOPE
          },
          report: {
            type: 'string',
            description:
              'public-surface-usage | owner-map | single-owner-shared | unused-public-surface | consumer-topology.',
            default: 'public-surface-usage'
          },
          limit: { type: 'number', description: 'Limit ranked/text output.', default: 25 },
          'exclude-tests': { type: 'boolean', description: 'Ignore test consumers.', default: false }
        })
        .run(({ flags }) => {
          emit(
            runTopology({
              json: flags.json,
              scope: flags.scope,
              report: flags.report,
              limit: flags.limit,
              excludeTests: flags['exclude-tests']
            }),
            flags.json
          )
        })
    )
    .command('all', cmd =>
      cmd
        .meta({ description: 'Run all gates + topology, aggregate exit code (CI entry).' })
        .flags({
          ...jsonFlag,
          skip: { type: 'string', description: 'Comma list of checks to skip, e.g. duplicates.' }
        })
        .run(async ({ flags }) => {
          await runAll({ json: flags.json, skip: flags.skip })
        })
    )
}
