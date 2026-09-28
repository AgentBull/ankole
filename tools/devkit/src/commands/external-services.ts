import { defineCommand } from '@crustjs/core'

import { runCompose, startComposeServices } from '../utils'

export function externalServicesCommand() {
  return defineCommand(
    'external-services',
    {
      aliases: ['ext', 'services'],
      description: 'Manage local Docker Compose services for Ankole Agent development.'
    },
    command =>
      command.add(
        defineCommand('start', { aliases: ['up'], description: 'Start Postgres.' }, child =>
          child
            .flags(
              {
                name: 'pull',
                type: 'boolean',
                description: 'Pull missing remote service images before starting.',
                default: false
              },
              {
                name: 'wait',
                type: 'boolean',
                description: 'Wait for service health checks.',
                default: true
              },
              {
                name: 'wait-timeout',
                type: 'number',
                description: 'Seconds to wait for service health checks.',
                default: 60
              }
            )
            .action(({ flags }) =>
              startComposeServices({
                pull: flags.pull,
                wait: flags.wait,
                waitTimeout: flags['wait-timeout']
              })
            )
        ),
        defineCommand('stop', { description: 'Stop Postgres without removing containers.' }, child =>
          child.action(() => runCompose(['stop']))
        ),
        defineCommand('restart', { description: 'Restart Postgres.' }, child =>
          child.action(() => runCompose(['restart']))
        ),
        defineCommand('remove', { aliases: ['down'], description: 'Stop and remove Compose containers.' }, child =>
          child
            .flags({
              name: 'volumes',
              type: 'boolean',
              description: 'Also remove named development data volumes.',
              default: false
            })
            .action(({ flags }) => runCompose(['down', '--remove-orphans', ...(flags.volumes ? ['--volumes'] : [])]))
        ),
        defineCommand('status', { aliases: ['ps'], description: 'Show Compose service status.' }, child =>
          child.action(() => runCompose(['ps']))
        ),
        defineCommand('pull', { description: 'Pull latest service images.' }, child =>
          child.action(() => runCompose(['pull']))
        ),
        defineCommand('logs', { description: 'Show Compose service logs.' }, child =>
          child.action(() => runCompose(['logs']))
        )
      )
  )
}
