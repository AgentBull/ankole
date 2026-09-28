import { defineCommand } from '@crustjs/core'
import { runCycles } from './cycles'
import { runSmells } from './smells'
import { runStructure } from './structure'
import type { CheckResult, ExitCode } from './types'
import { runUnused } from './unused'

const jsonFlag = { name: 'json', type: 'boolean', description: 'Emit machine-readable JSON.', default: false } as const

function emit(result: CheckResult, json: boolean): void {
  if (json) {
    process.stdout.write(`${JSON.stringify(result.json, null, 2)}\n`)
  } else {
    process.stdout.write(`${result.human}\n`)
  }
  process.exitCode = result.exitCode
}

/** Runs every gate and aggregates the exit code. */
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
    { name: 'structure', run: () => runStructure() },
    { name: 'cycles', run: () => runCycles() }
  ]

  const results: Array<{ name: string; result: CheckResult }> = []
  for (const gate of gates) {
    if (skip.has(gate.name)) {
      continue
    }
    results.push({ name: gate.name, result: await gate.run() })
  }

  const exitCode = results.reduce<ExitCode>(
    (max, entry) => (entry.result.exitCode > max ? entry.result.exitCode : max),
    0
  )

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

  for (const entry of results) {
    if (!entry.result.ok) {
      process.stdout.write(`${entry.result.human}\n\n`)
    }
  }
  process.stdout.write('analyze summary\n')
  for (const entry of results) {
    process.stdout.write(`  ${entry.name.padEnd(12)} ${entry.result.summary}\n`)
  }
  process.exitCode = exitCode
}

export function analyzeCommand() {
  return defineCommand(
    'analyze',
    {
      aliases: ['check'],
      description: 'Static repository checks for the Ankole monorepo.'
    },
    command =>
      command.add(
        defineCommand('smells', { description: 'Declared dependency-boundary gate.' }, child =>
          child.flags(jsonFlag).action(({ flags }) => {
            emit(runSmells({ json: flags.json }), flags.json)
          })
        ),
        defineCommand('unused', { description: 'Knip unused-file gate vs the owner/reason allowlist.' }, child =>
          child.flags(jsonFlag).action(async ({ flags }) => {
            emit(await runUnused({ json: flags.json }), flags.json)
          })
        ),
        defineCommand('structure', { description: 'konsistent structural convention gate.' }, child =>
          child.flags(jsonFlag).action(async ({ flags }) => {
            emit(await runStructure({ json: flags.json }), flags.json)
          })
        ),
        defineCommand('cycles', { description: 'Runtime-value import-cycle gate, target = 0.' }, child =>
          child
            .flags(jsonFlag, {
              name: 'include-tests',
              type: 'boolean',
              description: 'Include test files.',
              default: false
            })
            .action(({ flags }) => {
              emit(runCycles({ json: flags.json, includeTests: flags['include-tests'] }), flags.json)
            })
        ),
        defineCommand('all', { description: 'Run all gates and aggregate the exit code.' }, child =>
          child
            .flags(jsonFlag, {
              name: 'skip',
              type: 'string',
              description: 'Comma list of checks to skip, for example unused.'
            })
            .action(async ({ flags }) => {
              await runAll({ json: flags.json, skip: flags.skip })
            })
        )
      )
  )
}
