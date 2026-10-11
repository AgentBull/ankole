import { defineCommand } from '@crustjs/core'

import { pinWorkerBaseImage, warnIfBaseImageLockIsStale } from '../local-worker-image'

export function pinBaseImageCommand() {
  return defineCommand(
    'pin-base-image',
    { description: 'Pin the Agent OS base that CI published for a commit in app/agent_computer/base-image.lock.' },
    command =>
      command
        .args({
          name: 'revision',
          type: 'string',
          default: 'HEAD',
          description: 'Commit in the history of HEAD that has the Dockerfile.base of HEAD.'
        })
        .action(async ({ args }) => {
          const lock = await pinWorkerBaseImage(args.revision)
          console.log(lock.image)
          await warnIfBaseImageLockIsStale(lock)
        })
  )
}
