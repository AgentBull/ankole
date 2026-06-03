import 'reflect-metadata'
import { closeDatabase } from '@/common/database'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { webServer } from '@/core/web-server'
import { chatGatewayRuntime } from '@/chat-gateway'
import type { ChatGatewayRuntimeStats } from '@/chat-gateway/runtime'
import { pluginRuntime } from '@/plugins'
import type { PluginRuntimeStats } from '@/plugins/runtime'

interface MainWebServer {
  listen(options: { idleTimeout: number; port: number }): unknown
}

interface MainChatGatewayRuntime {
  start(): Promise<ChatGatewayRuntimeStats>
  stop(): Promise<void>
}

interface MainPluginRuntime {
  start(): Promise<PluginRuntimeStats>
  stop(): Promise<void>
}

interface MainLogger {
  error(data: unknown, message: string): void
  info(data: unknown, message: string): void
}

/**
 * Injectable startup dependencies for tests and future host runtimes.
 *
 * The real process path uses the module singletons. Tests pass fakes so they
 * can assert startup ordering without binding a network port or touching the
 * real Chat Gateway singleton.
 */
export interface StartBullXAgentOptions {
  closeDatabase?: typeof closeDatabase
  env?: string
  exitOnSignal?: boolean
  httpPort?: number
  chatGatewayRuntime?: MainChatGatewayRuntime
  logger?: MainLogger
  pluginRuntime?: MainPluginRuntime
  registerSignals?: boolean
  webServer?: MainWebServer
}

/**
 * Handle returned by `startBullXAgent()` for tests or embedders.
 */
export interface StartedBullXAgent {
  chatGateway: ChatGatewayRuntimeStats
  plugins: PluginRuntimeStats
  shutdown(signal?: NodeJS.Signals): Promise<void>
}

/**
 * Starts the BullX Agent process in dependency order.
 *
 * Chat Gateway must finish loading active agents and initializing Chat SDK
 * adapters before the HTTP server listens. Otherwise provider webhooks could
 * reach this process while their agent/channel instance is not ready yet.
 */
export async function startBullXAgent(options: StartBullXAgentOptions = {}): Promise<StartedBullXAgent> {
  const pluginsRuntime = options.pluginRuntime ?? pluginRuntime
  const runtime = options.chatGatewayRuntime ?? chatGatewayRuntime
  const server = options.webServer ?? webServer
  const log = options.logger ?? logger
  const closeDb = options.closeDatabase ?? closeDatabase
  const httpPort = options.httpPort ?? AppEnv.HTTP_PORT
  const env = options.env ?? AppEnv.NODE_ENV
  const registerSignals = options.registerSignals ?? true
  const exitOnSignal = options.exitOnSignal ?? true
  let shuttingDown = false

  const shutdownRuntime = async () => {
    // Stop ingress-capable runtime state before closing the shared database
    // connection, because Chat SDK shutdown hooks may still need persistence.
    await runtime.stop()
    await pluginsRuntime.stop()
    await closeDb({ timeout: 5 })
  }

  try {
    const plugins = await pluginsRuntime.start()
    const chatGateway = await runtime.start()

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
        chatGateway
      },
      'BullX Agent is running'
    )

    return {
      chatGateway,
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
  log: MainLogger
) {
  process.once(signal, () => {
    shutdown(signal).catch(error => {
      log.error({ error, signal }, 'Failed to shut down BullX Agent cleanly')
      process.exit(1)
    })
  })
}

if (import.meta.main) {
  try {
    await startBullXAgent()
  } catch (error) {
    logger.error({ error }, 'Failed to start BullX Agent')
    process.exit(1)
  }
}
