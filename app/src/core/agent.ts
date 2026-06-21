import { closeDatabase, databaseRuntimeConfig } from '@/common/database'
import { logger, type Logger } from '@/common/logger'
import { Computer } from '@agentbull/bullx-computer'
import { loadavg } from 'node:os'
import { AppEnv } from '@/config/env'
import { externalGatewayRuntime } from '@/external-gateway'
import type { ExternalGatewayRuntimeStats } from '@/external-gateway/runtime'
import { identityProviderRuntime } from '@/principals/identity-providers'
import type { IdentityProviderRuntimeStats } from '@/principals/identity-providers/runtime'
import { pluginRuntime } from '@/plugins'
import type { PluginRuntimeStats } from '@/plugins/runtime'
import { releaseComputerWorkerBinding, resolveComputerWorker } from '@/computer/service'
import { ensureComputerGitSshIdentity } from '@/computer/git-ssh-identity'
import { ensureComputerTlsBundle } from '@/computer/tls-config'
import { initializeSetupBootstrap } from '@/setup/bootstrap'
import { aiAgentRuntime } from '@/ai-agent/runtime'
import { buildAiAgentTools, registerBuiltinWebProviders } from '@/ai-agent/tools'
import { schedulerRuntime } from '@/scheduler'
import { syncBuiltinLibraryFromAppDirectory } from '@/ai-agent/library/service'
import { chatRecallRuntime } from '@/chat-recall/runtime'
import type { ChatRecallStatus } from '@/chat-recall/readiness'

const processShutdownStateKey = '__bullxAgentProcessShutdownState'

interface ProcessShutdownState {
  shuttingDown: boolean
  currentShutdown?: (signal: NodeJS.Signals) => Promise<void>
  signalHandlers: Partial<Record<NodeJS.Signals, true>>
}

/**
 * Handle returned by `startBullXAgent()` for tests or embedders.
 */
export interface StartedBullXAgent {
  chatRecall: ChatRecallStatus
  externalGateway: ExternalGatewayRuntimeStats
  identityProviders: IdentityProviderRuntimeStats
  plugins: PluginRuntimeStats
  shutdown(signal?: NodeJS.Signals): Promise<void>
}

/**
 * Starts the BullX Agent process in dependency order.
 *
 * External Gateway must finish loading active agents and initializing channel
 * adapters before realtime identity-provider listeners start and before the
 * HTTP server listens. This keeps shared channel connections attached to their
 * chat consumers before any long-connection IM event can arrive.
 */
export async function startBullXAgent(): Promise<StartedBullXAgent> {
  const processShutdownState = getProcessShutdownState()
  let pluginStartAttempted = false
  let externalGatewayStartAttempted = false
  let chatRecallStartAttempted = false
  let schedulerStartAttempted = false
  let identityProviderStartAttempted = false

  const shutdownRuntime = async () => {
    // Stop ingress-capable runtime state before closing the shared database
    // connection, because shutdown hooks may still need persistence.
    if (identityProviderStartAttempted) await identityProviderRuntime.stop()
    if (schedulerStartAttempted) await schedulerRuntime.stop()
    if (externalGatewayStartAttempted) await externalGatewayRuntime.stop()
    if (chatRecallStartAttempted) await chatRecallRuntime.stop()
    if (pluginStartAttempted) await pluginRuntime.stop()
    await closeDatabase({ timeout: 5 })
  }

  try {
    const setup = await initializeSetupBootstrap()
    await ensureComputerTlsBundle()
    await ensureComputerGitSshIdentity()
    await syncBuiltinLibraryFromAppDirectory()
    // Register built-in web providers before plugins so plugin-contributed providers append after them.
    registerBuiltinWebProviders()
    pluginStartAttempted = true
    const plugins = await pluginRuntime.start()
    // Wire AI agent tools once providers (built-in + plugin) and config are known, before the
    // gateway starts accepting messages. clarify is run-bound and enabled separately.
    const agentTools = await buildAiAgentTools()
    aiAgentRuntime.setTools(agentTools.staticTools, agentTools.activeNames)
    aiAgentRuntime.setClarifyEnabled(true)
    // Computer tools resolve the agent's sticky worker in-process via the control plane.
    aiAgentRuntime.setComputerEnabled(true, {
      resolveWorker: agentUid => resolveComputerWorker(agentUid),
      releaseWorkerBinding: (agentUid, worker) => releaseComputerWorkerBinding(agentUid, worker)
    })
    chatRecallStartAttempted = true
    const chatRecall = await chatRecallRuntime.start()
    aiAgentRuntime.setChatRecallEnabled(chatRecall.enabled)
    externalGatewayStartAttempted = true
    const externalGateway = await externalGatewayRuntime.start({
      getComputerFileWriter: (agentUid, signal) =>
        Computer.getOrCreate({
          agentUid,
          resolveWorker: uid => resolveComputerWorker(uid),
          signal
        })
    })
    schedulerStartAttempted = true
    await schedulerRuntime.start()
    identityProviderStartAttempted = true
    const identityProviders = await identityProviderRuntime.start()

    const shutdown = async (signal?: NodeJS.Signals) => {
      if (processShutdownState.shuttingDown) return

      processShutdownState.shuttingDown = true
      logger.info({ signal, snapshot: shutdownSnapshot() }, 'Shutting down BullX Agent')
      await shutdownRuntime()

      process.exit(exitCodeForShutdown(signal))
    }

    processShutdownState.currentShutdown = shutdown
    registerShutdownHandler('SIGINT', processShutdownState, logger)
    registerShutdownHandler('SIGTERM', processShutdownState, logger)

    logger.info(
      {
        env: AppEnv.NODE_ENV,
        database: {
          poolMax: databaseRuntimeConfig.poolMax,
          idleTimeoutSeconds: databaseRuntimeConfig.idleTimeoutSeconds
        },
        plugins,
        chatRecall: {
          enabled: chatRecall.enabled,
          disabledReasons: chatRecall.disabledReasons,
          worker: chatRecall.worker,
          stats: chatRecall.stats
        },
        identityProviders,
        externalGateway,
        setup: {
          completed: setup.completed
        }
      },
      'BullX Agent is running'
    )

    return {
      chatRecall,
      externalGateway,
      identityProviders,
      plugins,
      shutdown
    }
  } catch (error) {
    await shutdownRuntime()
    throw error
  }
}

/**
 * Registers one-shot process signal shutdown.
 */
function registerShutdownHandler(signal: NodeJS.Signals, state: ProcessShutdownState, log: Logger) {
  if (state.signalHandlers[signal]) return

  state.signalHandlers[signal] = true
  process.once(signal, () => {
    const shutdown = state.currentShutdown
    if (!shutdown) return

    shutdown(signal).catch(error => {
      log.error({ error, signal }, 'Failed to shut down BullX Agent cleanly')
      process.exit(1)
    })
  })
}

/**
 * Stores shutdown state on `globalThis` so Bun hot reload does not register
 * duplicate signal handlers in the same process.
 */
function getProcessShutdownState(): ProcessShutdownState {
  const globalScope = globalThis as typeof globalThis & {
    [processShutdownStateKey]?: ProcessShutdownState
  }

  return (globalScope[processShutdownStateKey] ??= {
    shuttingDown: false,
    signalHandlers: {}
  })
}

/**
 * Converts POSIX termination signals into conventional shell exit codes.
 */
function exitCodeForShutdown(signal: NodeJS.Signals | undefined): number {
  if (!signal) return 0
  const signalNumbers: Partial<Record<NodeJS.Signals, number>> = {
    SIGINT: 2,
    SIGTERM: 15
  }
  return 128 + (signalNumbers[signal] ?? 0)
}

/**
 * Captures low-cost process context for shutdown logs.
 */
function shutdownSnapshot() {
  return {
    pid: process.pid,
    ppid: process.ppid,
    uptimeSeconds: Math.round(process.uptime()),
    loadavg: loadavg()
  }
}
