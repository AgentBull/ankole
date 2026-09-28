import { defineCommand } from '@crustjs/core'

import { appRootPath, loadAppDevelopmentEnv, runMix } from '../utils'

export function localPasswordCommand() {
  return defineCommand(
    'local-password',
    { description: 'Manage local email-and-password sign-in accounts.' },
    command =>
      command.add(
        defineCommand(
          'reset',
          { description: 'Reset the local sign-in password for one email and print the new one-time password.' },
          child =>
            child
              .args({
                name: 'email',
                type: 'string',
                required: true,
                description: 'Email address of the account to reset.'
              })
              .action(async ({ args }) => {
                await runMix(['ankole.local_password.reset', args.email], {
                  cwd: appRootPath,
                  env: loadAppDevelopmentEnv()
                })
              })
        )
      )
  )
}
