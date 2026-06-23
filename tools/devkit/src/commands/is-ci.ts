import { env, exit } from 'node:process'
import { Crust } from '@crustjs/core'

const isCI = !!(env.CI || env.CONTINUOUS_INTEGRATION || env.BUILD_NUMBER || env.RUN_ID || false)

export function isCICommand(): Crust {
  return new Crust('is-ci')
    .meta({ description: 'Check if we are running in a CI environment, exit code with 1 if not and 0 if so.' })
    .run(() => exit(isCI ? 0 : 1))
}
