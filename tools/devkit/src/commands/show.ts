import { Crust } from '@crustjs/core'

import { appRootPath, loadAppDevelopmentEnv, runMix } from '../utils'

export function showCommand(): Crust {
  return new Crust('show')
    .meta({
      description: 'Show local Ankole values.'
    })
    .command('bootstrap-activation-code', command =>
      command.meta({ description: 'Show the current setup bootstrap activation code.' }).run(async () => {
        await runMix(['ankole.setup.bootstrap_activation_code'], {
          cwd: appRootPath,
          env: loadAppDevelopmentEnv()
        })
      })
    )
}
