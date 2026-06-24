import * as kernel from '../../kernel'
import { decodeEnvelope } from './actor_bus'
import {
  handleActorBusEnvelope,
  parseWorkerEnv,
  workerCapacityEnvelope,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from './runtime'

const heartbeatIntervalMs = 15_000

try {
  runWorker()
} catch (error) {
  process.stderr.write(
    `${JSON.stringify({
      event: 'worker.error',
      error: error instanceof Error ? error.message : String(error)
    })  }\n`
  )
  process.exit(1)
}

function runWorker(): void {
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
      })  }\n`
    )

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs

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
      for (const response of handleActorBusEnvelope(envelope)) {
        dealer.sendEnvelope(response)
      }
    }
  } finally {
    dealer.stop()
  }
}
