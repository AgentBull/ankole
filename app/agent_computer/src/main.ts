import { match } from '@agentbull/active-support'
import { toError } from './common/errors'
import { controlShutdownEnvelope } from './fabric/envelopes'
import { connectRuntimeFabric, type EnvelopeSender } from './fabric/fabric'
import type { Envelope } from './fabric/envelope_proto'
import { createFileTransferLane } from './lanes/file'
import { handleWorkerRPCRequest, RuntimeRPCClient, type WorkerRPCHandlers } from './lanes/rpc_lane'
import { configureRuntimeFabricTracing } from './observability/runtime-fabric-exporter'
import { forceFlushWorkerTracing } from './observability/turn-tracing'
import { ActiveTurns } from './worker/active_turns'
import { createWorkerBrowserRuntime } from './worker/browser'
import { loadWorkerConfig } from './worker/config'
import { WorkerDrainState } from './worker/drain'
import {
  heartbeatIntervalMs,
  sendWorkerHeartbeat,
  workerHeartbeatEnvelope,
  workerReadyEnvelope
} from './worker/lifecycle_messages'
import { workerLogger } from './worker/logging'
import { verifyWorkerReadiness } from './worker/readiness'
import { createWorkerRPCHandlers } from './worker/rpc_handlers'

try {
  await runWorker()
} catch (error) {
  workerLogger.critical('worker.error', 'worker failed', { error: toError(error) })
  process.exit(1)
}

/**
 * Runs the long-lived Agent Computer Worker process.
 *
 * The process owns RuntimeFabric transport, readiness, capacity, active Turns,
 * process drain, and ordered shutdown. Durable state remains in the control
 * plane and PostgreSQL.
 */
async function runWorker(): Promise<void> {
  const config = loadWorkerConfig()
  verifyWorkerReadiness(config)

  const fabric = connectRuntimeFabric(config)
  const sendEnvelope = fabric.sendEnvelope
  const rpcClient = new RuntimeRPCClient(sendEnvelope)
  configureRuntimeFabricTracing(rpcClient)

  const drain = new WorkerDrainState()
  const fileLane = createFileTransferLane(config, fabric.sendFileFrame)
  const browserRuntime = createWorkerBrowserRuntime()
  const activeTurns = new ActiveTurns(config, browserRuntime, sendEnvelope, rpcClient, drain)
  const workerRPCHandlers = createWorkerRPCHandlers(config, rpcClient, browserRuntime)

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      drain.begin(signal.toLowerCase())
    })
  }

  try {
    await browserRuntime.start()
    await sendEnvelope(workerReadyEnvelope(config, activeTurns.availableSlots))
    await activeTurns.publishCapacity()
    workerLogger.notice('worker.ready_sent', 'worker ready sent', {
      endpoint: config.endpoint,
      worker_id: config.workerID
    })

    let nextHeartbeatAt = Date.now() + heartbeatIntervalMs
    let shutdownReported = false
    // Span export is an RPC: it needs a reply, and only this loop delivers
    // replies. So the flush starts when the loop is otherwise done and the loop
    // keeps pumping until it settles, instead of running after the loop exits
    // where every export would wait out its timeout and lose its spans.
    let tracingFlush: Promise<void> | undefined
    let tracingFlushed = false

    for (;;) {
      if (!drain.acceptsTurns && !shutdownReported) {
        try {
          await sendEnvelope(controlShutdownEnvelope(drain.reason ?? 'process_shutdown'))
          shutdownReported = true
          workerLogger.notice('worker.draining', 'worker draining active tasks', {
            reason: drain.reason,
            active_tasks: drain.activeTaskCount,
            active_turns: activeTurns.size
          })
        } catch (error) {
          workerLogger.warning('worker.drain_report_failed', 'worker drain report failed', {
            reason: drain.reason,
            error: toError(error)
          })
        }
      }

      if (!drain.shouldContinue) {
        if (tracingFlushed) break
        tracingFlush ??= forceFlushWorkerTracing().finally(() => {
          tracingFlushed = true
        })
      }

      if (Date.now() >= nextHeartbeatAt) {
        await sendWorkerHeartbeat(
          sendEnvelope,
          workerHeartbeatEnvelope(config, Math.floor(performance.now()), activeTurns.size)
        )
        nextHeartbeatAt = Date.now() + heartbeatIntervalMs
      }

      const received = await fabric.receive(500)
      if (received.kind === 'timeout') continue

      if (received.kind === 'worker_file') {
        await fileLane.handle(received.frames)
        continue
      }

      const envelope = received.envelope
      workerLogger.debug('worker.envelope_received', 'runtime fabric envelope received', {
        envelope_type: envelope.body.case,
        message_id: envelope.messageId
      })
      await handleEnvelope(sendEnvelope, rpcClient, activeTurns, drain, workerRPCHandlers, envelope)
    }
  } finally {
    // A drained shutdown already flushed its spans inside the loop, where their
    // export could still be answered. This second flush covers the path that
    // leaves the loop by throwing; it has nothing to send after a clean drain.
    try {
      await browserRuntime.stop()
    } finally {
      try {
        await forceFlushWorkerTracing()
      } finally {
        fabric.stop()
      }
    }
  }
}

/**
 * Routes one decoded RuntimeFabric envelope to its concrete Worker owner.
 *
 * RuntimeFabric validates each envelope before this dispatcher. Each handled
 * lane validates its own payload.
 */
async function handleEnvelope(
  sendEnvelope: EnvelopeSender,
  rpcClient: RuntimeRPCClient,
  activeTurns: ActiveTurns,
  drain: WorkerDrainState,
  workerRPCHandlers: WorkerRPCHandlers,
  envelope: Envelope
): Promise<void> {
  return match(envelope.body)
    .with({ case: 'rpcResponse' }, ({ value }) => {
      rpcClient.resolve(value)
    })
    .with({ case: 'rpcError' }, ({ value }) => {
      rpcClient.resolve(value)
    })
    .with({ case: 'rpcRequest' }, ({ value }) => {
      // A handler can call the control plane. Do not await it here because this
      // receive loop must stay live to receive the matching RPC response.
      drain.track(
        handleWorkerRPCRequest(sendEnvelope, value, workerRPCHandlers).catch(error => {
          workerLogger.error('worker.rpc_reply_failed', 'worker RPC reply failed', {
            method: value.method,
            error: toError(error)
          })
        })
      )
    })
    .with({ case: 'turnStart' }, () => activeTurns.start(envelope))
    .with({ case: 'mailboxUpdated' }, () => activeTurns.mailboxUpdated(envelope))
    .with({ case: 'turnControl' }, () => activeTurns.control(envelope))
    .otherwise(body => {
      throw new Error(`RuntimeFabric protocol error: Worker cannot receive ${body.case ?? 'an empty body'}`)
    })
}
