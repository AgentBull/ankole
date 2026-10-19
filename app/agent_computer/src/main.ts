import { match, ms } from '@agentbull/active-support'
import { removeAbandonedRunDirectories } from './automation-jobs/run'
import { toError } from './common/errors'
import { createChannelTransport } from './fabric/channel_transport'
import { controlShutdownEnvelope } from './fabric/envelopes'
import type { EnvelopeSender, RuntimeFabricHost } from './fabric/fabric'
import type { Envelope } from './fabric/envelope_proto'
import { handleWorkerRPCRequest, RuntimeRPCClient } from './lanes/rpc_lane'
import { type WorkerRPCHandlers } from './lanes/rpc_contract'
import { configureRuntimeFabricTracing } from './observability/runtime-fabric-exporter'
import { forceFlushWorkerTracing } from './observability/turn-tracing'
import { ActiveTurns } from './worker/active_turns'
import { Workspaces } from './worker/workspaces'
import { createWorkerBrowserRuntime } from './worker/browser'
import { loadWorkerConfig } from './worker/config'
import { WorkerDrainState } from './worker/drain'
import { heartbeatIntervalMs, sendWorkerHeartbeat, Slots } from './worker/lifecycle_messages'
import { workerLogger } from './worker/logging'
import { verifyWorkerReadiness } from './worker/readiness'
import { createWorkerRPCHandlers } from './worker/rpc_handlers'

/** Time without a joined channel after which the Worker stops itself. */
const selfIsolationAfterMs = ms('5m')
/** Longest wait of one loop step, so that signals and isolation take effect in time. */
const loopStepMs = 500

try {
  await runWorker()
} catch (error) {
  workerLogger.critical('worker.error', 'worker failed', { error: toError(error) })
  process.exit(1)
}
// A drained Worker exits even if a handle is still open. `bun --watch`, which
// runs the development source, does not exit when the event loop is empty.
process.exit(0)

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

  // Phoenix calls this function again when the same process reconnects.
  const drain = new WorkerDrainState()
  const slots = new Slots(config, drain, envelope => fabric.sendEnvelope(envelope))
  const fabric = createChannelTransport(config, {
    joinParams: () => ({
      incarnation_id: config.incarnationID,
      max_slots: config.maxConcurrentSlots,
      available_slots: slots.available()
    })
  })
  const sendEnvelope = fabric.sendEnvelope
  const rpcClient = new RuntimeRPCClient(sendEnvelope, { awaitReady: fabric.awaitReady })
  configureRuntimeFabricTracing(rpcClient)

  const browserRuntime = createWorkerBrowserRuntime(config.browser)
  const activeTurns = new ActiveTurns(config, browserRuntime, sendEnvelope, rpcClient, drain, slots)
  const workspaces = new Workspaces(config, browserRuntime, sendEnvelope, rpcClient, drain, slots)
  const workerRPCHandlers = createWorkerRPCHandlers(config, rpcClient)

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      drain.begin(signal.toLowerCase())
      activeTurns.beginDrain()
      workspaces?.beginDrain()
    })
  }

  try {
    await browserRuntime.start()
    if (!(await awaitFirstAdmission(fabric, drain))) return
    // A late instance can have a revoked credential. It must not remove the
    // admitted Worker's run files before the control plane accepts its join.
    removeAbandonedRunDirectories(config)

    // The first heartbeat reports the load of this process at once.
    let nextHeartbeatAt = Date.now()
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
            active_slots: slots.used()
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

      assertNotIsolated(fabric)

      if (Date.now() >= nextHeartbeatAt) {
        // Without a channel, a heartbeat would wait for the rejoin and stall
        // this loop; the rejoin renews the row.
        if (fabric.isReady) {
          await sendWorkerHeartbeat(sendEnvelope, slots.heartbeat())
        }
        nextHeartbeatAt = Date.now() + heartbeatIntervalMs
      }

      const received = await fabric.receive(loopStepMs)
      if (received.kind === 'timeout') continue
      if (received.kind === 'disconnected') {
        rpcClient.disconnected(received.connectionID)
        continue
      }

      const envelope = received.envelope
      workerLogger.debug('worker.envelope_received', 'runtime fabric envelope received', {
        envelope_type: envelope.body.case,
        message_id: envelope.messageId
      })
      await handleEnvelope(sendEnvelope, rpcClient, activeTurns, workspaces, drain, workerRPCHandlers, envelope)
    }
  } finally {
    // A drained shutdown already flushed its spans inside the loop, where their
    // export could still be answered. This second flush covers the path that
    // leaves the loop by throwing; it has nothing to send after a clean drain.
    try {
      await workerRPCHandlers.close()
      await browserRuntime.stop()
    } finally {
      try {
        await forceFlushWorkerTracing()
      } finally {
        rpcClient.close()
        fabric.stop()
      }
    }
  }
}

/**
 * Waits until the control plane admits this process for the first time.
 *
 * The isolation rules of the main loop apply from the process start. Commands
 * that arrive in the meantime wait in the transport queue. Returns false when
 * a shutdown signal comes first, because the process has no work to drain.
 */
async function awaitFirstAdmission(fabric: RuntimeFabricHost, drain: WorkerDrainState): Promise<boolean> {
  while (!fabric.isReady) {
    if (!drain.acceptsTurns) return false
    assertNotIsolated(fabric)
    await Bun.sleep(loopStepMs)
  }
  return true
}

/**
 * Stops a Worker that the control plane no longer accepts, or that has had no
 * channel for too long; the supervisor in the image restarts it.
 */
function assertNotIsolated(fabric: RuntimeFabricHost): void {
  const isolation = fabric.isolationReason(selfIsolationAfterMs)
  if (isolation) throw new Error(`worker isolated itself from its Agent: ${isolation}`)
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
  workspaces: Workspaces,
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
    .with({ case: 'workspaceOpen' }, ({ value }) => workspaces.open(value))
    .with({ case: 'toolCall' }, ({ value }) => workspaces.call(value))
    .with({ case: 'toolCancel' }, ({ value }) => workspaces.cancel(value))
    .with({ case: 'workspaceClose' }, ({ value }) => {
      drain.track(workspaces.close(value))
    })
    .otherwise(body => {
      throw new Error(`RuntimeFabric protocol error: Worker cannot receive ${body.case ?? 'an empty body'}`)
    })
}
