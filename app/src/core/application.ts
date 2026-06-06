import { closeDatabase } from '@/common/database'
import type { Runtime } from '@/common/lifecycle'
import { logger, type Logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { externalGatewayRuntime } from '@/external-gateway'
import type { ExternalGatewayRuntimeStats } from '@/external-gateway/runtime'
import { identityProviderRuntime } from '@/principals/identity-providers'
import type { IdentityProviderRuntimeStats } from '@/principals/identity-providers/runtime'
import { pluginRuntime } from '@/plugins'
import type { PluginRuntimeStats } from '@/plugins/runtime'
import { initializeSetupBootstrap } from '@/setup/bootstrap'
import { createWebServer, type WebServerHandle } from './web-server'

/**
 * Injectable startup dependencies for tests and future host runtimes.
 *
 * The real process path uses the module singletons. Tests pass fakes so they
 * can assert startup ordering without binding a network port or touching the
 * real External Gateway singleton.
 */
export interface StartBullXAgentOptions {
  closeDatabase?: typeof closeDatabase
  env?: string
  exitOnSignal?: boolean
  httpPort?: number
  initializeSetupBootstrap?: typeof initializeSetupBootstrap
  externalGatewayRuntime?: Runtime<ExternalGatewayRuntimeStats>
  identityProviderRuntime?: Runtime<IdentityProviderRuntimeStats>
  logger?: Logger
  pluginRuntime?: Runtime<PluginRuntimeStats>
  registerSignals?: boolean
  webServer?: WebServerHandle
}

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
export async function startBullXAgent(options: StartBullXAgentOptions = {}): Promise<StartedBullXAgent> {
  const pluginsRuntime = options.pluginRuntime ?? pluginRuntime
  const identityRuntime = options.identityProviderRuntime ?? identityProviderRuntime
  const runtime = options.externalGatewayRuntime ?? externalGatewayRuntime
  const server = options.webServer ?? (await createWebServer())
  const log = options.logger ?? logger
  const closeDb = options.closeDatabase ?? closeDatabase
  const initSetup = options.initializeSetupBootstrap ?? initializeSetupBootstrap
  const httpPort = options.httpPort ?? AppEnv.HTTP_PORT
  const env = options.env ?? AppEnv.NODE_ENV
  const registerSignals = options.registerSignals ?? true
  const exitOnSignal = options.exitOnSignal ?? true
  let shuttingDown = false
  let pluginStartAttempted = false
  let externalGatewayStartAttempted = false
  let identityProviderStartAttempted = false

  const shutdownRuntime = async () => {
    // Stop ingress-capable runtime state before closing the shared database
    // connection, because shutdown hooks may still need persistence.
    if (identityProviderStartAttempted) await identityRuntime.stop()
    if (externalGatewayStartAttempted) await runtime.stop()
    if (pluginStartAttempted) await pluginsRuntime.stop()
    await closeDb({ timeout: 5 })
  }

  try {
    const setup = await initSetup()
    pluginStartAttempted = true
    const plugins = await pluginsRuntime.start()
    externalGatewayStartAttempted = true
    const externalGateway = await runtime.start()
    identityProviderStartAttempted = true
    const identityProviders = await identityRuntime.start()

    // From this point on the public webhook route can safely find initialized
    // agent/channel handlers.
    server.listen({
      port: httpPort,
      idleTimeout: 0
    })

    const shutdown = async (signal?: NodeJS.Signals) => {
      if (shuttingDown) return

      shuttingDown = true
      log.info({ signal }, 'Shutting down BullX Agent')
      await shutdownRuntime()

      if (exitOnSignal) process.exit(0)
    }

    if (registerSignals) {
      registerShutdownHandler('SIGINT', shutdown, log)
      registerShutdownHandler('SIGTERM', shutdown, log)
    }

    log.info(
      {
        port: httpPort,
        env,
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
