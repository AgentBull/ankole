import { Crust } from '@crustjs/core'
import chalk from 'chalk'

import { appRootPath, loadAppDevelopmentEnv, runMixCaptured } from '../utils'

const showKeys = ['bootstrap-activation-code'] as const
type ShowKey = (typeof showKeys)[number]

type GetValueResult = {
  key?: string | null
  value?: string | null
  completed?: boolean
}

export async function readAnkoleValue(key: ShowKey): Promise<GetValueResult> {
  const result = await runMixCaptured(['ankole.get', key, '--format', 'json'], {
    cwd: appRootPath,
    env: loadAppDevelopmentEnv()
  })

  if (result.status !== 0) {
    throw new Error(`Ankole value query failed: ${result.stderr || result.stdout}`)
  }

  return parseGetValueResult(result.stdout)
}

export function parseGetValueResult(output: string): GetValueResult {
  const jsonLine = output
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .findLast(line => line.startsWith('{') && line.endsWith('}'))

  if (!jsonLine) throw new Error('Ankole value query did not return JSON')

  const parsed = JSON.parse(jsonLine) as GetValueResult
  return {
    key: parsed.key ?? null,
    value: parsed.value ?? null,
    completed: parsed.completed === true
  }
}

export function showCommand(): Crust {
  return new Crust('show')
    .meta({
      description: 'Show local Ankole values.'
    })
    .args([
      {
        name: 'key',
        type: 'string',
        choices: showKeys,
        required: true,
        description: 'Value to show.'
      }
    ] as const)
    .run(async ({ args }) => {
      const key = args.key as ShowKey
      const result = await readAnkoleValue(key)

      if (key === 'bootstrap-activation-code') {
        printBootstrapActivationCode(result)
      }
    })
}

function printBootstrapActivationCode(result: GetValueResult): void {
  if (result.completed) {
    console.log(chalk.dim('Setup is already completed. No bootstrap activation code is active.'))
    return
  }

  if (result.value) {
    console.log(`${chalk.bold('SETUP ACTIVATION CODE:')} ${chalk.magentaBright(result.value)}`)
    return
  }

  console.log(chalk.yellow('Setup is open, but no bootstrap activation code is stored.'))
}
