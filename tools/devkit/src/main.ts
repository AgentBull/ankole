import { Crust } from '@crustjs/core'
import { didYouMeanPlugin, helpPlugin } from '@crustjs/plugins'
import { appDbCommand } from './commands/app-db'
import { externalServicesCommand } from './commands/external-services'
import { generateCommand, runGenerate } from './commands/generate'
import { isCICommand } from './commands/is-ci'
import { isDevCommand } from './commands/is-dev'
import { styledError } from './utils'

const rawArgv = process.argv.slice(2)
if (rawArgv[0] === 'generate' || rawArgv[0] === 'g') {
  await runGenerate(rawArgv.slice(1))
  process.exit(0)
}

let app = new Crust('bun run kit')
  .meta({ description: 'BullX Agent repository development toolkit.' })
  .use(didYouMeanPlugin({ mode: 'help' }))
  .use(helpPlugin())
  .command(isCICommand())
  .command(isDevCommand())
  .command(generateCommand())

app = app.command(externalServicesCommand())
app = app.command(appDbCommand())

try {
  await app.execute()
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  console.error(styledError(message))
  process.exit(1)
}
