import { Crust } from '@crustjs/core'

import { appRootPath, loadAppDevelopmentEnv, runMix } from '../utils'

export function localPasswordCommand(): Crust {
  return new Crust('local-password')
    .meta({
      description: 'Manage local email-and-password sign-in accounts.'
    })
    .command('reset', command =>
      command
        .meta({
          description: 'Reset the local sign-in password for one email and print the new one-time password.'
        })
        .args([
          {
            name: 'email',
            type: 'string',
            required: true,
            description: 'Email address of the account to reset.'
          }
        ] as const)
        .run(async ({ args }) => {
          await runMix(['ankole.local_password.reset', args.email], {
            cwd: appRootPath,
            env: loadAppDevelopmentEnv()
          })
        })
    )
}
