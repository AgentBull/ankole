import { env, exit } from 'node:process'
import { defineCommand } from '@crustjs/core'

const isDev = env.NODE_ENV !== 'production'

export function isDevCommand() {
  return defineCommand(
    'is-dev',
    { description: 'Check if we are running in a development environment, exit code with 1 if not and 0 if so.' },
    command => command.action(() => exit(isDev ? 0 : 1))
  )
}
