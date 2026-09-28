import { env, exit } from 'node:process'
import { defineCommand } from '@crustjs/core'

const isCI = !!(env.CI || env.CONTINUOUS_INTEGRATION || env.BUILD_NUMBER || env.RUN_ID || false)

export function isCICommand() {
  return defineCommand(
    'is-ci',
    { description: 'Check if we are running in a CI environment, exit code with 1 if not and 0 if so.' },
    command => command.action(() => exit(isCI ? 0 : 1))
  )
}
