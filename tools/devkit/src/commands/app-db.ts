import { Crust } from '@crustjs/core'

import { appRootPath, loadAppDevelopmentEnv, resolveAppDatabaseName, runChild, runCompose } from '../utils'

type DbArgs = {
  name?: string
  yes?: boolean
  migrate?: boolean
  startServices?: boolean
  pull?: boolean
  waitTimeout?: number
}

const commonDbFlags = {
  name: {
    type: 'string',
    description: 'Database name. Defaults to the database in app/.env.local or app/.env.development.'
  },
  'start-services': {
    type: 'boolean',
    description: 'Start the Postgres Compose service before the database operation.',
    default: true
  },
  pull: {
    type: 'boolean',
    description: 'Pull the latest Postgres image before starting services.',
    default: true
  },
  'wait-timeout': {
    type: 'number',
    description: 'Seconds to wait for Postgres health checks.',
    default: 60
  }
} as const

const startPostgres = async ({
  pull = true,
  waitTimeout = 60
}: Pick<DbArgs, 'pull' | 'waitTimeout'>): Promise<void> => {
  const args = ['up', '--detach', '--remove-orphans']
  if (pull) args.push('--pull', 'always')
  args.push('--wait', '--wait-timeout', String(waitTimeout), 'postgres')

  await runCompose(args)
}

const createDatabase = async (databaseName: string): Promise<void> => {
  await runCompose([
    'exec',
    '-T',
    '-e',
    `DB_NAME=${databaseName}`,
    'postgres',
    'sh',
    '-lc',
    [
      'set -eu',
      'if psql -U "$POSTGRES_USER" -d postgres -Atqc "SELECT datname FROM pg_database" | grep -Fxq "$DB_NAME"; then',
      '  echo "Database $DB_NAME already exists."',
      'else',
      '  createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$DB_NAME"',
      '  echo "Database $DB_NAME created."',
      'fi'
    ].join('\n')
  ])
}

const dropDatabase = async (databaseName: string): Promise<void> => {
  await runCompose([
    'exec',
    '-T',
    '-e',
    `DB_NAME=${databaseName}`,
    'postgres',
    'sh',
    '-lc',
    'dropdb -U "$POSTGRES_USER" --if-exists "$DB_NAME"'
  ])
}

const runAppMigrations = async (): Promise<void> => {
  await runChild('bun', ['run', 'migrate:local'], {
    cwd: appRootPath,
    env: loadAppDevelopmentEnv()
  })
}

const requireYes = (command: string, yes?: boolean): void => {
  if (yes) return

  throw new Error(`${command} is destructive. Re-run with --yes to confirm.`)
}

export function appDbCommand(): Crust {
  return new Crust('app-db')
    .meta({
      aliases: ['db'],
      description: 'Create, drop, or rebuild the BullX Agent app database.'
    })
    .command('create', cmd =>
      cmd
        .meta({ description: 'Create the app database if it does not already exist.' })
        .flags(commonDbFlags)
        .run(async ({ flags }) => {
          const databaseName = resolveAppDatabaseName(flags.name)
          if (flags['start-services']) {
            await startPostgres({
              pull: flags.pull,
              waitTimeout: flags['wait-timeout']
            })
          }
          await createDatabase(databaseName)
        })
    )
    .command('drop', cmd =>
      cmd
        .meta({ description: 'Drop the app database.' })
        .flags({
          ...commonDbFlags,
          yes: {
            type: 'boolean',
            description: 'Confirm the destructive drop operation.',
            default: false
          }
        })
        .run(async ({ flags }) => {
          requireYes('app-db drop', flags.yes)

          const databaseName = resolveAppDatabaseName(flags.name)
          if (flags['start-services']) {
            await startPostgres({
              pull: flags.pull,
              waitTimeout: flags['wait-timeout']
            })
          }
          await dropDatabase(databaseName)
        })
    )
    .command('rebuild', cmd =>
      cmd
        .meta({ description: 'Drop, create, and migrate the app database.' })
        .flags({
          ...commonDbFlags,
          yes: {
            type: 'boolean',
            description: 'Confirm the destructive rebuild operation.',
            default: false
          },
          migrate: {
            type: 'boolean',
            description: 'Run app Drizzle migrations after recreating the database.',
            default: true
          }
        })
        .run(async ({ flags }) => {
          requireYes('app-db rebuild', flags.yes)

          const databaseName = resolveAppDatabaseName(flags.name)
          if (flags['start-services']) {
            await startPostgres({
              pull: flags.pull,
              waitTimeout: flags['wait-timeout']
            })
          }
          await dropDatabase(databaseName)
          await createDatabase(databaseName)
          if (flags.migrate) await runAppMigrations()
        })
    )
    .command('migrate', cmd =>
      cmd
        .meta({ description: 'Run app Drizzle migrations against the configured local database.' })
        .run(() => runAppMigrations())
    )
}
