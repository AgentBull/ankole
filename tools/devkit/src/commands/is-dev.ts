import { env, exit } from 'node:process'
import { Crust } from '@crustjs/core'

const isDev = env.NODE_ENV === 'development' || env.NODE_ENV !== 'production'

export function isDevCommand(): Crust {
  return new Crust('is-dev')
    .meta({ description: 'Check if we are running in a development environment, exit code with 1 if not and 0 if so.' })
    .run(() => exit(isDev ? 0 : 1))
}
