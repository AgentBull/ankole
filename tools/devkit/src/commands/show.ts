import { defineCommand } from '@crustjs/core'

import { appRootPath, loadAppDevelopmentEnv, runMix } from '../utils'

export function showCommand() {
  return defineCommand('show', { description: 'Show local Ankole values.' }, command =>
    command.add(
      defineCommand(
        'bootstrap-activation-code',
        { description: 'Show the current setup bootstrap activation code.' },
        child =>
          child.action(async () => {
            await runMix(['ankole.setup.bootstrap_activation_code'], {
              cwd: appRootPath,
              env: loadAppDevelopmentEnv()
            })
          })
      )
    )
  )
}
