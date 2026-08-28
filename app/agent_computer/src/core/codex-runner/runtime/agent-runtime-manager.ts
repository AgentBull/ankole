import { jsonObject, ms } from '@agentbull/active-support'
import { lstat, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { errorMessage, toError } from '../../../common/errors'
import type { AgentLoopLogger } from '../../types'
import { CodexAppServerClient, CodexAppServerExitError, type JSONRPCMessage } from './app-server-client'
import type { CodexAppServerSandboxSpec } from './sandbox'
import { CODEX_HOME_LOCK_BUSY_EXIT_CODE, codexHomeLockedCommandArgv } from './codex-home-lock'
import { stringValue } from '../protocol'
import { installCodexLogs2LowLevelFilter } from './fix-codex-logs2-sqlite-bug'
import {
  codexAgentRuntimeBootstrapEnv,
  codexAgentRuntimeConfigPath,
  codexAIGatewayTokenPath,
  refreshCodexAgentRuntimeCredential
} from './agent-home-config'
import {
  installTrustAndDisableAgentPlugins,
  materializeAgentPluginPackages,
  type PreparedAgentPlugins
} from './agent-plugin-materializer'

/** Log threshold for slow initialization; it does not cancel startup. */
const INITIALIZE_SLOW_DIAGNOSTIC_MS = ms('1m')
/** Bound for cancellation and thread cleanup requests. */
const CLEANUP_REQUEST_TIMEOUT_MS = ms('5s')
/** Process memory bound for events that arrive before their thread owner. */
const MAX_PENDING_THREAD_NOTIFICATIONS = 256
/** Log bound for unscoped app-server stderr diagnostics. */
const MAX_RUNTIME_STDERR_DIAGNOSTIC_LENGTH = 2_048

/** Job callbacks used by the shared runtime without importing Job lifecycle. */
export interface AgentCodexRuntimeSession {
  prepareForRuntimeCleanup(): void
  handleRuntimeNotification(message: JSONRPCMessage): void
  handleRuntimeServerRequest(message: JSONRPCMessage, client: CodexAppServerClient): Promise<void>
  handleRuntimeLost(error: AgentCodexRuntimeLostError): void
}

export type AgentCodexRuntimeAcquireInput = {
  agentUID: string
  agentHome: string
  codexHome: string
  aiGatewayBaseURL: string
  aiGatewayAPIKey: string
  sandbox: CodexAppServerSandboxSpec
  logger?: AgentLoopLogger
  abortSignal?: AbortSignal
}

type RuntimeEntry = {
  agentUID: string
  codexHome: string
  startup: Promise<AgentCodexRuntime>
  runtime?: AgentCodexRuntime
  waiters: number
  leases: number
  closing?: Promise<void>
}

export class AgentCodexRuntimeLostError extends Error {
  readonly code = 'runtime_lost'
  readonly retryable = true

  constructor(agentUID: string, cause: unknown) {
    super(`Agent Codex runtime was lost for ${agentUID}: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'AgentCodexRuntimeLostError'
  }
}

export class AgentCodexRuntimeBusyError extends Error {
  readonly code = 'agent_codex_runtime_busy'
  readonly retryable = true

  constructor(agentUID: string, cause: CodexAppServerExitError) {
    super(`Another Worker owns the active Codex runtime for Agent ${agentUID}`, { cause })
    this.name = 'AgentCodexRuntimeBusyError'
  }
}

/** Keeps a shared Agent runtime alive until one Job session releases it. */
export class AgentCodexRuntimeLease {
  private released = false

  constructor(
    private readonly manager: AgentCodexRuntimeManager,
    private readonly entry: RuntimeEntry,
    readonly runtime: AgentCodexRuntime
  ) {}

  async release(): Promise<void> {
    if (this.released) return
    this.released = true
    await this.manager.release(this.entry, this.runtime)
  }
}

/** Owns one Agent-scoped app-server entry and leases it to Job sessions. */
export class AgentCodexRuntimeManager {
  private readonly entries = new Map<string, RuntimeEntry>()

  async acquire(input: AgentCodexRuntimeAcquireInput): Promise<AgentCodexRuntimeLease> {
    input.abortSignal?.throwIfAborted()
    const existing = this.entries.get(input.agentUID)
    if (existing?.closing) {
      await waitWithAbort(existing.closing, input.abortSignal)
      return this.acquire(input)
    }

    const entry = existing ?? this.createEntry(input)
    if (entry.codexHome !== input.codexHome) {
      throw new Error(`Agent ${input.agentUID} Codex Home changed while its runtime was active`)
    }

    entry.waiters += 1
    try {
      const runtime = await waitWithAbort(entry.startup, input.abortSignal)
      await runtime.refreshAIGatewayCredential(input.codexHome, input.aiGatewayAPIKey)
      entry.runtime = runtime
      entry.leases += 1
      return new AgentCodexRuntimeLease(this, entry, runtime)
    } finally {
      entry.waiters -= 1
      if (entry.waiters === 0 && entry.leases === 0) void this.closeUnusedEntry(entry)
    }
  }

  async release(entry: RuntimeEntry, runtime: AgentCodexRuntime): Promise<void> {
    if (entry.runtime !== runtime || entry.leases <= 0) return
    entry.leases -= 1
    if (entry.leases === 0 && entry.waiters === 0) await this.closeUnusedEntry(entry)
  }

  activeRuntimeCount(agentUID?: string): number {
    if (agentUID) return this.entries.get(agentUID)?.runtime ? 1 : 0
    return [...this.entries.values()].filter(entry => entry.runtime).length
  }

  private createEntry(input: AgentCodexRuntimeAcquireInput): RuntimeEntry {
    const entry: RuntimeEntry = {
      agentUID: input.agentUID,
      codexHome: input.codexHome,
      waiters: 0,
      leases: 0,
      startup: this.startRuntime(input, error => this.runtimeExited(entry, error))
    }
    this.entries.set(input.agentUID, entry)
    void entry.startup.catch(() => {
      if (this.entries.get(input.agentUID) === entry) this.entries.delete(input.agentUID)
    })
    return entry
  }

  private async startRuntime(
    input: AgentCodexRuntimeAcquireInput,
    onExit: (error: Error) => void
  ): Promise<AgentCodexRuntime> {
    await removeFormerAgentHomeConfig(input.agentHome)

    const runtimeRef: { current?: AgentCodexRuntime } = {}
    const client = new CodexAppServerClient({
      cwd: input.sandbox.cwd,
      env: {
        ...input.sandbox.env,
        ...codexAgentRuntimeBootstrapEnv(input.codexHome, input.aiGatewayBaseURL, input.aiGatewayAPIKey)
      },
      commandArgv: codexHomeLockedCommandArgv({
        codexHome: input.codexHome,
        commandArgv: input.sandbox.commandArgv,
        deleteLogsBeforeCommand: true,
        runtimeFiles: {
          configPath: codexAgentRuntimeConfigPath(input.codexHome),
          tokenPath: codexAIGatewayTokenPath(input.codexHome)
        }
      }),
      onNotification: message => runtimeRef.current?.routeNotification(message),
      onServerRequest: (message, appServer) =>
        runtimeRef.current?.routeServerRequest(message, appServer) ??
        appServer.respondError(message.id!, -32603, 'Agent runtime router is not ready'),
      onExit: error => onExit(error)
    })
    const runtime = new AgentCodexRuntime(input.agentUID, client, input.logger)
    runtimeRef.current = runtime

    const startedAt = Date.now()
    const slowTimer = setTimeout(() => {
      input.logger?.warning(
        'worker.codex_app_server_initialize_slow',
        'Codex app-server initialization is still running',
        { agent_uid: input.agentUID, duration_ms: Date.now() - startedAt }
      )
    }, INITIALIZE_SLOW_DIAGNOSTIC_MS)
    slowTimer.unref?.()
    try {
      const initializeResponse = await client.initialize()
      runtime.setInitializeResponse(initializeResponse)
      input.logger?.info('worker.codex_app_server_initialized', 'Codex app-server initialized', {
        agent_uid: input.agentUID,
        duration_ms: Date.now() - startedAt,
        process_id: client.processID
      })
      const status = installCodexLogs2LowLevelFilter(input.codexHome)
      input.logger?.info('worker.codex_logs2_filter_ready', 'Codex logs filter is ready', {
        agent_uid: input.agentUID,
        status
      })
      return runtime
    } catch (error) {
      await client.closeAndWait()
      if (error instanceof CodexAppServerExitError && error.exitCode === CODEX_HOME_LOCK_BUSY_EXIT_CODE) {
        throw new AgentCodexRuntimeBusyError(input.agentUID, error)
      }
      throw error
    } finally {
      clearTimeout(slowTimer)
    }
  }

  private runtimeExited(entry: RuntimeEntry, error: Error): void {
    entry.runtime?.markLost(new AgentCodexRuntimeLostError(entry.agentUID, error))
    if (this.entries.get(entry.agentUID) === entry) this.entries.delete(entry.agentUID)
  }

  private async closeUnusedEntry(entry: RuntimeEntry): Promise<void> {
    if (entry.closing) return entry.closing
    entry.closing = (async () => {
      try {
        const runtime = entry.runtime ?? (await entry.startup.catch(() => undefined))
        await runtime?.close()
      } finally {
        if (this.entries.get(entry.agentUID) === entry) this.entries.delete(entry.agentUID)
      }
    })()
    return entry.closing
  }
}

async function removeFormerAgentHomeConfig(agentHome: string): Promise<void> {
  const formerCodexHome = join(agentHome, '.codex')

  try {
    if (!(await lstat(formerCodexHome)).isDirectory()) return
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
    throw error
  }

  const configPath = join(formerCodexHome, 'config.toml')
  try {
    if (!(await lstat(configPath)).isDirectory()) await unlink(configPath)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
}

/**
 * Routes app-server events by thread owner.
 * A session owns its root and child threads. It cannot observe or clean another
 * session's threads.
 */
export class AgentCodexRuntime {
  private readonly threadOwners = new Map<string, AgentCodexRuntimeSession>()
  private readonly sessionThreads = new Map<AgentCodexRuntimeSession, Set<string>>()
  private readonly activeTurns = new Map<string, string>()
  private readonly pendingServerRequests = new Map<AgentCodexRuntimeSession, Set<Promise<void>>>()
  private readonly pendingThreadNotifications = new Map<string, JSONRPCMessage[]>()
  private readonly sessionTurnIdleWaiters = new Map<AgentCodexRuntimeSession, Set<() => void>>()
  private readonly retiredThreadIDs = new Set<string>()
  private readonly retiredThreadCleanupVersions = new Map<string, number>()
  private readonly retiredThreadCleanupTasks = new Map<string, Promise<void>>()
  private readonly threadTransitions = new Map<string, Promise<void>>()
  private readonly sessionCleanupTasks = new Map<AgentCodexRuntimeSession, Promise<void>>()
  private pendingThreadNotificationCount = 0
  private agentSetup = Promise.resolve()
  private pluginsInitialized = false
  private pluginCatalogSignature: string | undefined
  private lost?: AgentCodexRuntimeLostError
  private closing = false
  initializeResponse: Record<string, unknown> = {}

  constructor(
    readonly agentUID: string,
    readonly client: CodexAppServerClient,
    private readonly logger?: AgentLoopLogger
  ) {}

  async registerRoot(threadID: string, session: AgentCodexRuntimeSession): Promise<void> {
    await this.runThreadTransition(threadID, async () => {
      if (this.lost) throw this.lost
      const owner = this.threadOwners.get(threadID)
      if (owner && owner !== session) throw new Error(`Codex thread ${threadID} is already owned by another Job`)
      this.retiredThreadIDs.delete(threadID)
      this.retiredThreadCleanupVersions.delete(threadID)
      this.registerThread(threadID, session)
      this.drainPendingThreadNotifications(threadID)
    })
  }

  async resumeRoot(threadID: string, session: AgentCodexRuntimeSession, resume: () => Promise<void>): Promise<void> {
    const currentOwner = this.threadOwners.get(threadID)
    const retiringOwner = currentOwner && currentOwner !== session ? currentOwner : undefined
    const pendingCleanup = retiringOwner ? this.sessionCleanupTasks.get(retiringOwner) : undefined
    if (pendingCleanup) await pendingCleanup.catch(() => undefined)

    await this.runThreadTransition(threadID, async () => {
      if (this.lost) throw this.lost
      const owner = this.threadOwners.get(threadID)
      if (owner && owner !== session) {
        throw new Error(`Codex thread ${threadID} is already owned by another Job`)
      }

      this.retiredThreadIDs.delete(threadID)
      this.retiredThreadCleanupVersions.delete(threadID)
      this.registerThread(threadID, session)
      this.drainPendingThreadNotifications(threadID)

      try {
        await resume()
      } catch (error) {
        this.unregisterThread(threadID, session)
        this.retiredThreadIDs.add(threadID)
        this.dropPendingThreadNotifications(threadID)
        this.scheduleRetiredThreadCleanup(threadID)
        throw error
      }
    })
  }

  async ensureAgentPlugins(input: { cwd: string; prepared: PreparedAgentPlugins }): Promise<void> {
    await this.runAgentSetup(async () => {
      if (this.lost) throw this.lost
      const signature = JSON.stringify({
        marketplace: input.prepared.marketplacePath,
        plugins: input.prepared.agentPlugins.map(agentPlugin => ({
          id: agentPlugin.id,
          version: agentPlugin.manifestVersion,
          source: agentPlugin.sourceRoot,
          materialized: agentPlugin.materializedRoot
        }))
      })
      if (this.pluginCatalogSignature && this.pluginCatalogSignature !== signature) {
        throw new Error(`Agent ${this.agentUID} Plugin catalog changed while its Codex runtime was active`)
      }

      materializeAgentPluginPackages(input.prepared, { rebuild: !this.pluginsInitialized })
      if (this.pluginsInitialized) return
      if (this.threadOwners.size > 0) {
        throw new Error('Agent Plugin installation must finish before the first Job thread starts')
      }
      await installTrustAndDisableAgentPlugins(this.client, input.cwd, input.prepared)
      this.pluginCatalogSignature = signature
      this.pluginsInitialized = true
      this.logger?.info('worker.codex_agent_plugins_ready', 'Agent Codex runtime Plugins are ready', {
        agent_uid: this.agentUID,
        plugin_count: input.prepared.agentPlugins.length
      })
    })
  }

  async refreshAIGatewayCredential(codexHome: string, apiKey: string): Promise<void> {
    await this.runAgentSetup(() => refreshCodexAgentRuntimeCredential(codexHome, apiKey))
  }

  unregisterThread(threadID: string, session: AgentCodexRuntimeSession): void {
    if (this.threadOwners.get(threadID) !== session) return
    this.threadOwners.delete(threadID)
    this.activeTurns.delete(threadID)
    const threads = this.sessionThreads.get(session)
    threads?.delete(threadID)
    if (threads?.size === 0) this.sessionThreads.delete(session)
    this.resolveSessionTurnIdleWaiters(session)
  }

  async waitForSessionTurnsIdle(session: AgentCodexRuntimeSession): Promise<void> {
    if (!this.sessionHasActiveTurns(session)) return
    await new Promise<void>(resolve => {
      const waiters = this.sessionTurnIdleWaiters.get(session) ?? new Set<() => void>()
      waiters.add(resolve)
      this.sessionTurnIdleWaiters.set(session, waiters)
    })
  }

  setInitializeResponse(response: Record<string, unknown>): void {
    this.initializeResponse = response
  }

  routeNotification(message: JSONRPCMessage): void {
    const params = jsonObject(message.params)
    const thread = jsonObject(params.thread)
    const threadID = stringValue(params.threadId) ?? stringValue(thread.id)
    const childLink = childThreadLink(message, threadID, thread)
    let registeredChildThreadID: string | undefined
    if (childLink) {
      const { parentThreadID, childThreadID } = childLink
      const parentOwner = parentThreadID ? this.threadOwners.get(parentThreadID) : undefined
      if (parentOwner) {
        this.registerThread(childThreadID, parentOwner)
        registeredChildThreadID = childThreadID
      } else if (parentThreadID && this.retiredThreadIDs.has(parentThreadID)) {
        this.retiredThreadIDs.add(childThreadID)
        this.scheduleRetiredThreadCleanup(childThreadID)
        return
      } else if (parentThreadID) {
        this.bufferThreadNotification(parentThreadID, message)
        return
      }
    }

    if (threadID && this.retiredThreadIDs.has(threadID)) {
      this.trackActiveTurn(message, threadID)
      this.scheduleRetiredThreadCleanup(threadID)
      return
    }

    if (threadID) this.trackActiveTurn(message, threadID)
    const owner = threadID ? this.threadOwners.get(threadID) : undefined
    if (owner) {
      owner.handleRuntimeNotification(message)
      if (registeredChildThreadID) this.drainPendingThreadNotifications(registeredChildThreadID)
      this.resolveSessionTurnIdleWaiters(owner)
      return
    }

    if (threadID) {
      this.bufferThreadNotification(threadID, message)
      return
    }

    const stderrDiagnostic = runtimeStderrDiagnostic(message)
    this.logger?.info('worker.codex_runtime_unscoped_event', 'Codex runtime emitted an unscoped event', {
      agent_uid: this.agentUID,
      method: message.method ?? 'unknown',
      ...(threadID ? { thread_id: threadID } : {}),
      ...(stderrDiagnostic ? { diagnostic: stderrDiagnostic } : {})
    })
  }

  async routeServerRequest(message: JSONRPCMessage, appServer: CodexAppServerClient): Promise<void> {
    if (message.id === undefined) return
    const threadID = stringValue(jsonObject(message.params).threadId)
    const owner = threadID ? this.threadOwners.get(threadID) : undefined
    if (!owner) {
      await appServer.respondError(message.id, -32602, 'Codex server request has no owned Job thread')
      return
    }

    const pending: Promise<void> = owner
      .handleRuntimeServerRequest(message, appServer)
      .finally(() => this.pendingServerRequests.get(owner)?.delete(pending))
    const requests = this.pendingServerRequests.get(owner) ?? new Set<Promise<void>>()
    requests.add(pending)
    this.pendingServerRequests.set(owner, requests)
    await pending
  }

  cleanupSession(session: AgentCodexRuntimeSession): Promise<void> {
    const current = this.sessionCleanupTasks.get(session)
    if (current) return current

    const cleanup = this.doCleanupSession(session).finally(() => {
      if (this.sessionCleanupTasks.get(session) === cleanup) this.sessionCleanupTasks.delete(session)
    })
    this.sessionCleanupTasks.set(session, cleanup)
    return cleanup
  }

  private async doCleanupSession(session: AgentCodexRuntimeSession): Promise<void> {
    session.prepareForRuntimeCleanup()
    let firstError: unknown

    // Stop new server requests, settle accepted requests, and then clean each
    // owned thread. The second settle includes requests accepted before cleanup.
    try {
      await this.settlePendingServerRequests(session)
    } catch (error) {
      firstError = error
    }

    while (true) {
      const threads = this.sessionThreads.get(session)
      const threadID = threads ? [...threads].at(-1) : undefined
      if (!threadID) break
      try {
        await this.runThreadTransition(threadID, async () => {
          if (this.threadOwners.get(threadID) !== session) return
          try {
            await this.cleanupThreadRuntime(threadID)
          } finally {
            this.retiredThreadIDs.add(threadID)
            this.unregisterThread(threadID, session)
            this.dropPendingThreadNotifications(threadID)
          }
        })
      } catch (error) {
        firstError ??= error
      }
    }
    try {
      await this.settlePendingServerRequests(session)
    } catch (error) {
      firstError ??= error
    }
    this.sessionThreads.delete(session)
    this.pendingServerRequests.delete(session)
    if (firstError) throw firstError
  }

  markLost(error: AgentCodexRuntimeLostError): void {
    if (this.lost || this.closing) return
    this.lost = error
    for (const session of new Set(this.threadOwners.values())) session.handleRuntimeLost(error)
    for (const waiters of this.sessionTurnIdleWaiters.values()) {
      for (const resolve of waiters) resolve()
    }
    this.sessionTurnIdleWaiters.clear()
  }

  async close(): Promise<void> {
    if (this.closing) return
    this.closing = true
    await this.client.closeAndWait()
  }

  private registerThread(threadID: string, session: AgentCodexRuntimeSession): void {
    const owner = this.threadOwners.get(threadID)
    if (owner && owner !== session) throw new Error(`Codex thread ${threadID} is already owned by another Job`)
    this.threadOwners.set(threadID, session)
    const threads = this.sessionThreads.get(session) ?? new Set<string>()
    threads.add(threadID)
    this.sessionThreads.set(session, threads)
  }

  private async cleanupThreadRuntime(threadID: string): Promise<void> {
    let firstError: unknown
    const turnID = this.activeTurns.get(threadID)
    if (turnID) {
      try {
        await this.client.request('turn/interrupt', { threadId: threadID, turnId: turnID }, CLEANUP_REQUEST_TIMEOUT_MS)
      } catch (error) {
        firstError = error
      }
    }
    try {
      await this.terminateBackgroundTerminals(threadID)
    } catch (error) {
      firstError ??= error
    }
    try {
      await this.client.request('thread/backgroundTerminals/clean', { threadId: threadID }, CLEANUP_REQUEST_TIMEOUT_MS)
    } catch (error) {
      firstError ??= error
    }
    try {
      await this.client.request('thread/unsubscribe', { threadId: threadID }, CLEANUP_REQUEST_TIMEOUT_MS)
    } catch (error) {
      firstError ??= error
    }
    if (firstError) throw firstError
  }

  private scheduleRetiredThreadCleanup(threadID: string): void {
    this.retiredThreadCleanupVersions.set(threadID, (this.retiredThreadCleanupVersions.get(threadID) ?? 0) + 1)
    if (this.retiredThreadCleanupTasks.has(threadID)) return

    const task = this.cleanupRetiredThreadUntilStable(threadID).finally(() => {
      this.retiredThreadCleanupTasks.delete(threadID)
    })
    this.retiredThreadCleanupTasks.set(threadID, task)
  }

  private async cleanupRetiredThreadUntilStable(threadID: string): Promise<void> {
    // Late child events can add cleanup work. Stop only after one cleanup pass
    // receives no new event.
    while (true) {
      const version = this.retiredThreadCleanupVersions.get(threadID) ?? 0
      await this.runThreadTransition(threadID, async () => {
        if (!this.retiredThreadIDs.has(threadID)) return
        try {
          await this.cleanupThreadRuntime(threadID)
        } catch (error) {
          this.logger?.warning(
            'worker.codex_runtime_retired_thread_cleanup_failed',
            'Codex runtime could not clean a late child thread',
            {
              agent_uid: this.agentUID,
              thread_id: threadID,
              error: toError(error)
            }
          )
        } finally {
          this.dropPendingThreadNotifications(threadID)
        }
      })
      if (!this.retiredThreadIDs.has(threadID)) return
      if ((this.retiredThreadCleanupVersions.get(threadID) ?? 0) === version) {
        this.activeTurns.delete(threadID)
        return
      }
    }
  }

  private async runThreadTransition(threadID: string, transition: () => Promise<void>): Promise<void> {
    const previous = this.threadTransitions.get(threadID) ?? Promise.resolve()
    const current = previous.catch(() => undefined).then(transition)
    this.threadTransitions.set(threadID, current)
    try {
      await current
    } finally {
      if (this.threadTransitions.get(threadID) === current) this.threadTransitions.delete(threadID)
    }
  }

  private dropPendingThreadNotifications(threadID: string): void {
    const pending = this.pendingThreadNotifications.get(threadID)
    if (!pending) return
    this.pendingThreadNotifications.delete(threadID)
    this.pendingThreadNotificationCount -= pending.length
  }

  private bufferThreadNotification(threadID: string, message: JSONRPCMessage): void {
    if (this.pendingThreadNotificationCount >= MAX_PENDING_THREAD_NOTIFICATIONS) {
      this.logger?.warning(
        'worker.codex_runtime_pending_event_dropped',
        'Codex runtime dropped an unowned thread event after reaching the buffer limit',
        { agent_uid: this.agentUID, thread_id: threadID, method: message.method ?? 'unknown' }
      )
      return
    }
    const pending = this.pendingThreadNotifications.get(threadID) ?? []
    pending.push(message)
    this.pendingThreadNotifications.set(threadID, pending)
    this.pendingThreadNotificationCount += 1
  }

  private drainPendingThreadNotifications(threadID: string): void {
    const pending = this.pendingThreadNotifications.get(threadID)
    if (!pending) return
    this.pendingThreadNotifications.delete(threadID)
    this.pendingThreadNotificationCount -= pending.length
    for (const message of pending) this.routeNotification(message)
  }

  private trackActiveTurn(message: JSONRPCMessage, threadID: string): void {
    const turn = jsonObject(jsonObject(message.params).turn)
    const turnID = stringValue(turn.id) ?? stringValue(jsonObject(message.params).turnId)
    if (message.method === 'turn/started' && turnID) this.activeTurns.set(threadID, turnID)
    if (message.method === 'turn/completed') this.activeTurns.delete(threadID)
  }

  private sessionHasActiveTurns(session: AgentCodexRuntimeSession): boolean {
    const threads = this.sessionThreads.get(session)
    return Boolean(threads && [...threads].some(threadID => this.activeTurns.has(threadID)))
  }

  private resolveSessionTurnIdleWaiters(session: AgentCodexRuntimeSession): void {
    if (this.sessionHasActiveTurns(session)) return
    const waiters = this.sessionTurnIdleWaiters.get(session)
    if (!waiters) return
    this.sessionTurnIdleWaiters.delete(session)
    for (const resolve of waiters) resolve()
  }

  private async terminateBackgroundTerminals(threadID: string): Promise<void> {
    let cursor: string | undefined
    do {
      const response = jsonObject(
        await this.client.request(
          'thread/backgroundTerminals/list',
          { threadId: threadID, ...(cursor ? { cursor } : {}) },
          CLEANUP_REQUEST_TIMEOUT_MS
        )
      )
      const terminals = Array.isArray(response.data) ? response.data.map(jsonObject) : []
      for (const terminal of terminals) {
        const processID = stringValue(terminal.processId)
        if (!processID) continue
        await this.client.request(
          'thread/backgroundTerminals/terminate',
          { threadId: threadID, processId: processID },
          CLEANUP_REQUEST_TIMEOUT_MS
        )
      }
      cursor = stringValue(response.nextCursor)
    } while (cursor)
  }

  private async settlePendingServerRequests(session: AgentCodexRuntimeSession): Promise<void> {
    const pending = [...(this.pendingServerRequests.get(session) ?? [])]
    if (pending.length === 0) return
    await withTimeout(
      Promise.allSettled(pending).then(() => undefined),
      CLEANUP_REQUEST_TIMEOUT_MS,
      'Codex server requests did not settle after Job cancellation'
    )
  }

  private async runAgentSetup(operation: () => void | Promise<void>): Promise<void> {
    // Serialize Agent Home credential and Plugin updates across Job sessions.
    if (this.lost) throw this.lost
    const current = this.agentSetup.then(async () => {
      if (this.lost) throw this.lost
      await operation()
    })
    this.agentSetup = current.then(
      () => undefined,
      () => undefined
    )
    await current
  }
}

function runtimeStderrDiagnostic(message: JSONRPCMessage): string | undefined {
  if (message.method !== '$stderr') return undefined
  const text = stringValue(jsonObject(message.params).text)?.trim()
  if (!text) return undefined

  return text
    .replace(/(authorization\s*[:=]\s*)(?:(?:bearer|basic)\s+)?\S+/gi, '$1[REDACTED]')
    .replace(/((?:api[_-]?key|token|secret|password)\s*[:=]\s*)\S+/gi, '$1[REDACTED]')
    .replace(/\b(?:bx_mcp|sk)[_-][A-Za-z0-9_-]+\b/g, '[REDACTED]')
    .replace(/\b[A-Za-z0-9_-]{48,}\b/g, '[REDACTED]')
    .replace(/\s+/g, ' ')
    .slice(0, MAX_RUNTIME_STDERR_DIAGNOSTIC_LENGTH)
}

function childThreadLink(
  message: JSONRPCMessage,
  eventThreadID: string | undefined,
  thread: Record<string, unknown>
): { parentThreadID: string; childThreadID: string } | undefined {
  if (message.method === 'thread/started') {
    const parentThreadID = stringValue(thread.parentThreadId)
    const childThreadID = stringValue(thread.id)
    return parentThreadID && childThreadID ? { parentThreadID, childThreadID } : undefined
  }

  if ((message.method !== 'item/started' && message.method !== 'item/completed') || !eventThreadID) return undefined
  const item = jsonObject(jsonObject(message.params).item)
  if (item.type !== 'subAgentActivity' || item.kind !== 'started') return undefined
  const childThreadID = stringValue(item.agentThreadId)
  return childThreadID ? { parentThreadID: eventThreadID, childThreadID } : undefined
}

/** Process-wide owner of Agent-scoped Codex app-server entries. */
export const agentCodexRuntimeManager = new AgentCodexRuntimeManager()

function waitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  signal?.throwIfAborted()
  if (!signal) return promise
  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => reject(signal.reason ?? new DOMException('Runtime acquire was aborted', 'AbortError'))
    signal.addEventListener('abort', onAbort, { once: true })
    void promise.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(message)), timeoutMs)
    timeout.unref?.()
    void promise.then(
      value => {
        clearTimeout(timeout)
        resolve(value)
      },
      error => {
        clearTimeout(timeout)
        reject(error)
      }
    )
  })
}
