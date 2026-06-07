import { closeDatabase } from '@/common/database'
import { logger, type Logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { externalGatewayRuntime } from '@/external-gateway'
import type { ExternalGatewayRuntimeStats } from '@/external-gateway/runtime'
import { identityProviderRuntime } from '@/principals/identity-providers'
import type { IdentityProviderRuntimeStats } from '@/principals/identity-providers/runtime'
import { pluginRuntime } from '@/plugins'
import type { PluginRuntimeStats } from '@/plugins/runtime'
import { initializeSetupBootstrap } from '@/setup/bootstrap'
import { aiAgentRuntime } from '@/ai-agent/runtime'
import { buildAiAgentTools, registerBuiltinWebProviders } from '@/ai-agent/tools'

/**
 * Handle returned by `startBullXAgent()` for tests or embedders.
 */
export interface StartedBullXAgent {
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
  let shuttingDown = false
  let pluginStartAttempted = false
  let externalGatewayStartAttempted = false
  let identityProviderStartAttempted = false

  const shutdownRuntime = async () => {
    // Stop ingress-capable runtime state before closing the shared database
    // connection, because shutdown hooks may still need persistence.
    if (identityProviderStartAttempted) await identityProviderRuntime.stop()
    if (externalGatewayStartAttempted) await externalGatewayRuntime.stop()
    if (pluginStartAttempted) await pluginRuntime.stop()
    await closeDatabase({ timeout: 5 })
  }

  try {
    const setup = await initializeSetupBootstrap()
    // Register built-in web providers before plugins so plugin-contributed providers append after them.
    registerBuiltinWebProviders()
    pluginStartAttempted = true
    const plugins = await pluginRuntime.start()
    // Wire AI agent tools once providers (built-in + plugin) and config are known, before the
    // gateway starts accepting messages. clarify is run-bound and enabled separately.
    const agentTools = await buildAiAgentTools()
    aiAgentRuntime.setTools(agentTools.staticTools, agentTools.activeNames)
    aiAgentRuntime.setClarifyEnabled(true)
    externalGatewayStartAttempted = true
    const externalGateway = await externalGatewayRuntime.start()
    identityProviderStartAttempted = true
    const identityProviders = await identityProviderRuntime.start()

    const shutdown = async (signal?: NodeJS.Signals) => {
      if (shuttingDown) return

      shuttingDown = true
      logger.info({ signal }, 'Shutting down BullX Agent')
      await shutdownRuntime()

      process.exit(0)
    }

    registerShutdownHandler('SIGINT', shutdown, logger)
    registerShutdownHandler('SIGTERM', shutdown, logger)

    logger.info(
      {
        env: AppEnv.NODE_ENV,
        idleTimeoutSeconds: 0,
        plugins,
        identityProviders,
        externalGateway,
        setup: {
          completed: setup.completed
        }
      },
      'BullX Agent is running'
    )

    return {
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
function registerShutdownHandler(
  signal: NodeJS.Signals,
  shutdown: (signal: NodeJS.Signals) => Promise<void>,
  log: Logger
) {
  process.once(signal, () => {
    shutdown(signal).catch(error => {
      log.error({ error, signal }, 'Failed to shut down BullX Agent cleanly')
      process.exit(1)
    })
  })
}
