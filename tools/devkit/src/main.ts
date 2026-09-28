import { Crust } from '@crustjs/core'
import { didYouMean, help } from '@crustjs/extensions'
import { analyzeCommand } from './commands/analyze'
import { agentComputerTestCommand } from './commands/agent-computer-test'
import { appDBCommand } from './commands/app-db'
import { devCommand } from './commands/dev'
import { envSetupCommand } from './commands/env-setup'
import { externalServicesCommand } from './commands/external-services'
import { generateCommand, runGenerate } from './commands/generate'
import { isCICommand } from './commands/is-ci'
import { isDevCommand } from './commands/is-dev'
import { localPasswordCommand } from './commands/local-password'
import { logsCommand } from './commands/logs'
import { showCommand } from './commands/show'
import { exitCodeForError, styledError } from './utils'

const rawArgv = process.argv.slice(2)
if (rawArgv[0] === 'generate' || rawArgv[0] === 'g') {
  // Angular schematics parse arguments differently from Crust. Dispatching here
  // keeps generator compatibility without leaking that parser into other commands.
  await runGenerate(rawArgv.slice(1))
  process.exit(0)
}

const app = new Crust('bun kit', { description: 'Ankole Agent repository development toolkit.' })
  .extend(didYouMean({ mode: 'help' }), help())
  .add(
    isCICommand(),
    isDevCommand(),
    generateCommand(),
    externalServicesCommand(),
    envSetupCommand(),
    appDBCommand(),
    agentComputerTestCommand(),
    devCommand(),
    localPasswordCommand(),
    logsCommand(),
    showCommand(),
    analyzeCommand()
  )

try {
  await app.execute()
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  console.error(styledError(message))
  process.exit(exitCodeForError(error))
}
