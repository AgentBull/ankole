import * as kernel from '../../kernel'
import { decodeEnvelope } from './actor_bus'
import {
  credentialRequestEnvelope,
  credentialResponseFromEnvelope,
  handleActorBusEnvelope,
  parseWorkerEnv,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from './runtime'

const heartbeatIntervalMs = 15_000

try {
  await runWorker()
} catch (error) {
  process.stderr.write(
    `${JSON.stringify({
      event: 'worker.error',
      error: error instanceof Error ? error.message : String(error)
    })}\n`
  )
  process.exit(1)
}

/**
 * Runs the standalone computer worker event loop.
 *
 * The worker uses a DEALER socket because the control plane routes by worker
 * instance id. All actor-specific state is carried by envelopes, so shutdown
 * only needs to close the transport.
 */
async function runWorker(): Promise<void> {
  const config = parseWorkerEnv()
  const ready = workerReadyEnvelope(config)
  const dealer = new kernel.ActorBusDealer(
    config.endpoint,
    config.workerInstanceId,
    config.workerId,
    config.preAuthToken
  )
  let stopping = false

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      stopping = true
    })
  }

  try {
    dealer.sendEnvelope(ready)
    dealer.sendEnvelope(workerCapacityEnvelope(config))
    process.stdout.write(
      `${JSON.stringify({
        event: 'worker.ready_sent',
        endpoint: config.endpoint,
        worker_id: config.workerId,
        worker_instance_id: config.workerInstanceId
      })}\n`
    )

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs

    // Heartbeat and receive share one loop to keep this bootstrap worker small.
    // The full AI loop can move turn handling behind the same envelope boundary.
    while (!stopping) {
      if (Date.now() >= nextHeartbeatAt) {
        dealer.sendEnvelope(workerHeartbeatEnvelope(config))
        nextHeartbeatAt = Date.now() + heartbeatIntervalMs
      }

      const bytes = dealer.recv(500)
      if (!bytes) {
        continue
      }

      const envelope = decodeEnvelope(bytes)
      for (const response of await handleActorBusEnvelope(envelope, config, {
        requestCredential: async request => {
          dealer.sendEnvelope(credentialRequestEnvelope(request))
          const deadline = Date.now() + 120_000

          while (Date.now() < deadline) {
            const bytes = dealer.recv(500)
            if (!bytes) {
              continue
            }

            const envelope = decodeEnvelope(bytes)
            const response = credentialResponseFromEnvelope(envelope, request.request_id)
            if (response) {
              return response
            }
          }

          throw new Error(`timed out waiting for credential response ${request.request_id}`)
        }
      })) {
        dealer.sendEnvelope(response)
      }
    }
  } finally {
    dealer.stop()
  }
}
