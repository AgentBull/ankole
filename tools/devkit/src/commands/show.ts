import { Crust } from '@crustjs/core'
import chalk from 'chalk'

import {
  bootstrapActivationCodeLabelWithColon,
  bootstrapActivationCodeStatus,
  type BootstrapActivationCodeState
} from './bootstrap-activation-code'
import { appRootPath, loadAppDevelopmentEnv, runMixCaptured } from '../utils'

const showKeys = ['bootstrap-activation-code'] as const
type ShowKey = (typeof showKeys)[number]

type GetValueResult = BootstrapActivationCodeState & {
  key?: string | null
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
  const status = bootstrapActivationCodeStatus(result)
  switch (status.kind) {
    case 'completed':
      console.log(chalk.dim(status.text))
      return
    case 'active':
      console.log(`${chalk.bold(bootstrapActivationCodeLabelWithColon)} ${chalk.magentaBright(status.code)}`)
      return
    case 'missing':
      console.log(chalk.yellow(status.text))
      return
  }
}
