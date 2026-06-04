import { Crust } from '@crustjs/core'

import { runCompose } from '../utils'

type StartArgs = {
  pull?: boolean
  wait?: boolean
  waitTimeout?: number
}

const startServices = async ({ pull = true, wait = true, waitTimeout = 60 }: StartArgs): Promise<void> => {
  const args = ['up', '--detach', '--remove-orphans']
  if (pull) args.push('--pull', 'always')
  if (wait) args.push('--wait', '--wait-timeout', String(waitTimeout))

  await runCompose(args)
}

export function externalServicesCommand(): Crust {
  return new Crust('external-services')
    .meta({
      aliases: ['ext', 'services'],
      description: 'Manage local Docker Compose services for BullX Agent development.'
    })
    .command('start', cmd =>
      cmd
        .meta({
          aliases: ['up'],
          description: 'Start Postgres and Redis.'
        })
        .flags({
          pull: {
            type: 'boolean',
            description: 'Pull latest service images before starting.',
            default: true
          },
          wait: {
            type: 'boolean',
            description: 'Wait for service health checks.',
            default: true
          },
          'wait-timeout': {
            type: 'number',
            description: 'Seconds to wait for service health checks.',
            default: 60
          }
        })
        .run(({ flags }) =>
          startServices({
            pull: flags.pull,
            wait: flags.wait,
            waitTimeout: flags['wait-timeout']
          })
        )
    )
    .command('stop', cmd =>
      cmd.meta({ description: 'Stop Postgres and Redis without removing containers.' }).run(() => runCompose(['stop']))
    )
    .command('restart', cmd =>
      cmd.meta({ description: 'Restart Postgres and Redis.' }).run(() => runCompose(['restart']))
    )
    .command('remove', cmd =>
      cmd
        .meta({
          aliases: ['down'],
          description: 'Stop and remove Compose containers.'
        })
        .flags({
          volumes: {
            type: 'boolean',
            description: 'Also remove named development data volumes.',
            default: false
          }
        })
        .run(({ flags }) => runCompose(['down', '--remove-orphans', ...(flags.volumes ? ['--volumes'] : [])]))
    )
    .command('status', cmd =>
      cmd
        .meta({
          aliases: ['ps'],
          description: 'Show Compose service status.'
        })
        .run(() => runCompose(['ps']))
    )
    .command('pull', cmd =>
      cmd.meta({ description: 'Pull latest Postgres and Redis images.' }).run(() => runCompose(['pull']))
    )
    .command('logs', cmd => cmd.meta({ description: 'Show Compose service logs.' }).run(() => runCompose(['logs'])))
}
