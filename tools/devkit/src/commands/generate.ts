import { join } from 'node:path'
import { chdir } from 'node:process'

import { main } from '@angular-devkit/schematics-cli/bin/schematics'
import { Crust } from '@crustjs/core'
import chalk from 'chalk'

import { packageRootPath, repoRootPath } from '../utils'

const defaultCollection = '@agentbull/devkit'
const collectionPath = join(packageRootPath, 'src/schematics/collection.json')

export function generateCommand(): Crust {
  return new Crust('generate')
    .meta({
      aliases: ['g'],
      description: 'Generates and/or modifies files based on schematic.'
    })
    .run(() => showUsage())
}

export async function runGenerate(args: string[]): Promise<void> {
  if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
    showUsage()
    return
  }

  if (!args[0]?.includes(':')) args[0] = `${collectionPath}:${args[0]}`

  const schematicsArgs = [...args]
  const hasDebug = hasOption(args, 'debug')
  const hasDryRun = hasOption(args, 'dry-run') || hasOption(args, 'dryRun')

  if (!hasDebug) schematicsArgs.push('--no-debug')
  if (!hasDryRun) schematicsArgs.push('--no-dry-run')

  chdir(repoRootPath)
  await main({ args: schematicsArgs })
}

function showUsage(): void {
  process.stdout.write(`bun run kit generate [collection-name:]<schematic-name> [options]

Common Options:
  --debug           Debug mode. Use --no-debug to disable it.
  --allow-private   Allow private schematics to be run.
  --dry-run         Do not actually execute any effects.
  --force           Force overwriting files that would otherwise be an error.
  --no-interactive  Do not prompt for input.
  --verbose         Show more output.
  --help            Show help.

Available schematics in ${defaultCollection} collection:\n`)

  void main({ args: [`${collectionPath}:`, '--list-schematics'] })
  process.stdout.write(`
By default, if the collection name is not specified, use the internal collection provided by ${defaultCollection}.
e.g. "${chalk.bold('bun run kit g code-workspace')}" equals "${chalk.bold(`bun run kit g ${defaultCollection}:code-workspace`)}".
`)
}

function hasOption(args: string[], name: string): boolean {
  return args.some(arg => arg === `--${name}` || arg === `--no-${name}` || arg.startsWith(`--${name}=`))
}
