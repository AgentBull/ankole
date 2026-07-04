import { mkdirSync, rmSync } from 'node:fs'
import { resolve, relative, join } from 'node:path'
import type { JsonObject } from '../../fabric/fabric'
import type {
  AIGatewayApiKeyRejected,
  AIGatewayApiKeyRequest,
  AIGatewayApiKeyResponse,
  AppConfigureResolveRejected,
  AppConfigureResolveRequest,
  AppConfigureResolveResponse,
  CodexDelegationCreateRequest,
  CodexDelegationEventAppendRequest,
  CodexDelegationGetRequest,
  CodexDelegationRejected,
  CodexDelegationResponse,
  CodexDelegationStatusUpdateRequest
} from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import { CodexAppServerClient, type JsonRpcMessage } from './app-server-client'
import {
  CodexConfigOverrideKey,
  codexConfigCliOverrides,
  materializeCodexConfig,
  parseCodexConfigOverride
} from './config'

export type CodexDelegationStatus =
  | 'queued'
  | 'running'
  | 'waiting_on_user'
  | 'succeeded'
  | 'failed'
  | 'stopped'
  | 'timeout'

export type CodexDelegateRequest = {
  prompt: string
  workdir?: string
  timeoutSeconds?: number
  outputSchema?: unknown
}

export type CodexDelegationSnapshot = {
  delegation_id: string
  agent_uid: string
  session_id: string
  status: CodexDelegationStatus
  codex_thread_id?: string
  codex_turn_id?: string
  workdir: string
  queued_at_unix_ms: number
  started_at_unix_ms?: number
  completed_at_unix_ms?: number
  output_text?: string
  error?: string
  waiting_on_user?: JsonObject
  last_event_seq?: number
  result_ref?: JsonObject
}

export type CodexRuntimeRequesters = {
  requestAIGatewayApiKey: (
    request: AIGatewayApiKeyRequest,
    options?: { forceRefresh?: boolean }
  ) => Promise<AIGatewayApiKeyResponse | AIGatewayApiKeyRejected>
  requestAppConfigure?: (
    request: AppConfigureResolveRequest
  ) => Promise<AppConfigureResolveResponse | AppConfigureResolveRejected>
  createCodexDelegation?: (
    request: CodexDelegationCreateRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
  getCodexDelegationStatus?: (
    request: CodexDelegationGetRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
  appendCodexDelegationEvent?: (request: CodexDelegationEventAppendRequest) => Promise<unknown>
  updateCodexDelegationStatus?: (
    request: CodexDelegationStatusUpdateRequest
  ) => Promise<CodexDelegationResponse | CodexDelegationRejected>
}

export type CodexSubmitOptions = {
  turnStart: TurnStart
  workspaceRoot: string
  toolCallId: string
  request: CodexDelegateRequest
  requesters: CodexRuntimeRequesters
  signal?: AbortSignal
}

type PendingUserInput = {
  requestId: string | number
  params: JsonObject
}

type CodexJob = {
  delegationId: string
  agentUid: string
  sessionId: string
  actorEventId: string
  toolCallId: string
  workspaceRoot: string
  workdir: string
  prompt: string
  outputSchema?: unknown
  timeoutSeconds: number
  requesters: CodexRuntimeRequesters
  status: CodexDelegationStatus
  queuedAtUnixMs: number
  startedAtUnixMs?: number
  completedAtUnixMs?: number
  codexThreadId?: string
  codexTurnId?: string
  outputText: string
  error?: string
  pendingUserInput?: PendingUserInput
  client?: CodexAppServerClient
  cleanupRoot?: string
  seq: number
  auditTail: Promise<void>
  auditError?: Error
  waiters: Set<() => void>
  abortController: AbortController
}

const maxRunningPerAgent = 3
const defaultTimeoutSeconds = 30 * 60
const queueRetryDelayMs = 1000
const terminalStatuses = new Set<CodexDelegationStatus>(['succeeded', 'failed', 'stopped', 'timeout'])

export class CodexDelegationManager {
  private jobs = new Map<string, CodexJob>()
  private queuedByAgent = new Map<string, CodexJob[]>()
  private runningByAgent = new Map<string, Set<string>>()

  async submit(opts: CodexSubmitOptions): Promise<CodexDelegationSnapshot> {
    const create = opts.requesters.createCodexDelegation
    if (!create) throw new Error('Codex delegation audit RPC is not configured')

    const workdir = resolveCodexWorkdir(opts.workspaceRoot, opts.request.workdir)
    mkdirSync(workdir, { recursive: true })

    const created = await create({
      request_id: `codex-create-${crypto.randomUUID()}`,
      agent_uid: opts.turnStart.turn.actor.agent_uid,
      session_id: opts.turnStart.turn.actor.session_id,
      actor_event_id: opts.turnStart.turn.actor_event_id,
      tool_call_id: opts.toolCallId,
      workdir,
      status: 'queued',
      metadata: {
        output_schema: jsonObjectOrEmpty(opts.request.outputSchema),
        prompt_chars: opts.request.prompt.length
      }
    })

    if ('code' in created) throw new Error(`Codex audit create rejected: ${created.code} ${created.message ?? ''}`)

    const job: CodexJob = {
      delegationId: created.delegation_id,
      agentUid: opts.turnStart.turn.actor.agent_uid,
      sessionId: opts.turnStart.turn.actor.session_id,
      actorEventId: opts.turnStart.turn.actor_event_id,
      toolCallId: opts.toolCallId,
      workspaceRoot: opts.workspaceRoot,
      workdir,
      prompt: opts.request.prompt,
      outputSchema: opts.request.outputSchema,
      timeoutSeconds: opts.request.timeoutSeconds ?? defaultTimeoutSeconds,
      requesters: opts.requesters,
      status: 'queued',
      queuedAtUnixMs: Date.now(),
      outputText: '',
      seq: 0,
      auditTail: Promise.resolve(),
      waiters: new Set(),
      abortController: new AbortController()
    }

    this.jobs.set(job.delegationId, job)
    await this.audit(job, 'queue', 'queued', { workdir: modelPath(job.workspaceRoot, job.workdir) })
    this.enqueue(job)
    this.pump(job.agentUid)
    return snapshot(job)
  }

  get(delegationId: string): CodexDelegationSnapshot | null {
    const job = this.jobs.get(delegationId)
    return job ? snapshot(job) : null
  }

  async wait(delegationId: string, signal?: AbortSignal): Promise<CodexDelegationSnapshot> {
    const job = this.requireJob(delegationId)
    while (!terminalStatuses.has(job.status) && job.status !== 'waiting_on_user') {
      await waitForJobChange(job, signal)
    }
    return snapshot(job)
  }

  async steer(
    delegationId: string,
    text: string,
    answers?: Record<string, string | string[]>
  ): Promise<CodexDelegationSnapshot> {
    const job = this.requireJob(delegationId)
    if (!job.client || !job.codexThreadId) throw new Error('Codex delegation is not running in this worker')

    if (job.pendingUserInput) {
      const response = userInputResponse(job.pendingUserInput.params, text, answers)
      await job.client.respond(job.pendingUserInput.requestId, response)
      await this.audit(job, 'tool', 'user_input_answered', { response })
      job.pendingUserInput = undefined
      await this.setStatus(job, 'running')
      return snapshot(job)
    }

    if (!job.codexTurnId) throw new Error('Codex delegation does not have an active turn')

    await job.client.request('turn/steer', {
      threadId: job.codexThreadId,
      expectedTurnId: job.codexTurnId,
      input: textInput(text)
    })
    await this.audit(job, 'tool', 'turn_steer', { text })
    return snapshot(job)
  }

  async stop(delegationId: string): Promise<CodexDelegationSnapshot> {
    const job = this.requireJob(delegationId)

    if (job.status === 'queued') {
      this.removeQueued(job)
      await this.finish(job, 'stopped', { reason: 'stopped_before_start' })
      return snapshot(job)
    }

    if (job.client && job.codexThreadId && job.codexTurnId) {
      await job.client.request('turn/interrupt', {
        threadId: job.codexThreadId,
        turnId: job.codexTurnId
      })
    }
    job.abortController.abort(new DOMException('codex delegation stopped', 'AbortError'))
    await this.finish(job, 'stopped', { reason: 'stopped' })
    return snapshot(job)
  }

  private enqueue(job: CodexJob): void {
    const queue = this.queuedByAgent.get(job.agentUid) ?? []
    queue.push(job)
    this.queuedByAgent.set(job.agentUid, queue)
    this.notify(job)
  }

  private pump(agentUid: string): void {
    const running = this.runningByAgent.get(agentUid) ?? new Set<string>()
    const queue = this.queuedByAgent.get(agentUid) ?? []

    while (running.size < maxRunningPerAgent && queue.length > 0) {
      const job = queue.shift()!
      running.add(job.delegationId)
      this.runningByAgent.set(agentUid, running)
      void this.run(job)
        .catch(error => {
          this.recordAsyncError(job, error)
        })
        .finally(() => {
          running.delete(job.delegationId)
          this.pump(agentUid)
        })
    }
  }

  private async run(job: CodexJob): Promise<void> {
    try {
      const acquired = await this.acquireRunningSlot(job)
      if (!acquired) return
      await this.runCodex(job)
    } catch (error) {
      if (!terminalStatuses.has(job.status)) {
        await this.finish(job, job.abortController.signal.aborted ? 'stopped' : 'failed', {
          error: error instanceof Error ? error.message : String(error)
        })
      }
    } finally {
      if (terminalStatuses.has(job.status)) await job.client?.close()
      if (terminalStatuses.has(job.status) && job.cleanupRoot) {
        rmSync(job.cleanupRoot, { recursive: true, force: true })
        job.cleanupRoot = undefined
      }
      await this.flushAudit(job)
    }
  }

  private async acquireRunningSlot(job: CodexJob): Promise<boolean> {
    const response = await this.sendStatusUpdate(job, { status: 'running' })

    if ('code' in response) {
      if (response.code === 'codex_agent_running_limit_exceeded') {
        await this.audit(job, 'queue', 'global_running_limit_deferred', {
          max_running_per_agent: maxRunningPerAgent,
          message: response.message ?? 'Codex delegation remains queued'
        })
        this.scheduleRequeue(job)
        return false
      }

      throw new Error(`Codex audit status rejected: ${response.code} ${response.message ?? ''}`)
    }

    job.status = 'running'
    if (!job.startedAtUnixMs) job.startedAtUnixMs = Date.now()
    await this.audit(job, 'process', 'status_running', {})
    this.notify(job)
    return true
  }

  private async runCodex(job: CodexJob): Promise<void> {
    const override = await resolveConfigOverride(job)
    const aiGatewayKey = override?.mode === 'official_subscription' ? undefined : await resolveAIGatewayKey(job)
    const modelOverride = override?.mode === 'official_subscription' ? undefined : 'coding'
    const materialized = materializeCodexConfig({
      workspaceRoot: job.workspaceRoot,
      delegationId: job.delegationId,
      override,
      aiGatewayKey
    })
    job.cleanupRoot = materialized.cleanupRoot

    await this.audit(job, 'process', 'config_materialized', {
      mode: override?.mode ?? 'aigateway',
      codex_home: modelPath(job.workspaceRoot, materialized.codexHome),
      has_auth_json: override?.auth_json !== undefined
    })

    const client = new CodexAppServerClient({
      cwd: job.workdir,
      env: materialized.env,
      args: codexConfigCliOverrides(),
      audit: (direction, message) => this.enqueueAudit(job, direction, 'json_rpc', { message }),
      onExit: error => this.handleClientExit(job, error),
      onNotification: message => this.handleNotification(job, message),
      onServerRequest: async (message, appServer) => {
        try {
          await this.handleServerRequest(job, message, appServer)
        } catch (error) {
          this.recordAsyncError(job, error)
          await this.finish(job, 'failed', {
            error: error instanceof Error ? error.message : String(error)
          })
        }
      }
    })
    job.client = client

    const timeout = setTimeout(() => {
      void this.finish(job, 'timeout', { error: `Codex delegation timed out after ${job.timeoutSeconds}s` }).catch(
        error => this.recordAsyncError(job, error)
      )
      job.abortController.abort(new DOMException('codex delegation timed out', 'TimeoutError'))
    }, job.timeoutSeconds * 1000)

    try {
      await client.initialize()
      const threadStart = (await client.request('thread/start', {
        cwd: job.workdir,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        ...(modelOverride ? { model: modelOverride } : {})
      })) as JsonObject

      const thread = jsonObject(threadStart.thread)
      job.codexThreadId = stringValue(thread.id)
      if (!job.codexThreadId) throw new Error('codex app-server did not return a thread id')
      await this.updateStatus(job, { status: 'running', codex_thread_id: job.codexThreadId })

      const turnStart = (await client.request('turn/start', {
        threadId: job.codexThreadId,
        input: textInput(job.prompt),
        cwd: job.workdir,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        ...(modelOverride ? { model: modelOverride } : {}),
        ...(job.outputSchema ? { outputSchema: job.outputSchema } : {})
      })) as JsonObject
      const turn = jsonObject(turnStart.turn)
      job.codexTurnId = stringValue(turn.id)

      while (!terminalStatuses.has(job.status)) {
        await waitForJobChange(job, job.abortController.signal)
      }
    } finally {
      clearTimeout(timeout)
    }
  }

  private handleNotification(job: CodexJob, message: JsonRpcMessage): void {
    const method = typeof message.method === 'string' ? message.method : ''
    const params = jsonObject(message.params)

    if (method === '$stderr') {
      this.enqueueAudit(job, 'process', 'stderr', params)
      return
    }

    if (method === 'turn/started') {
      const turn = jsonObject(params.turn)
      job.codexTurnId = stringValue(turn.id) || job.codexTurnId
    }

    if (method === 'item/agentMessage/delta' && typeof params.delta === 'string') {
      job.outputText += params.delta
    }

    if (method === 'turn/completed') {
      const turn = jsonObject(params.turn)
      const status = stringValue(turn.status)
      const terminal: CodexDelegationStatus =
        status === 'completed' ? 'succeeded' : status === 'interrupted' ? 'stopped' : 'failed'
      void this.finish(job, terminal, {
        codex_turn_status: status || 'unknown',
        output_text: job.outputText
      }).catch(error => this.recordAsyncError(job, error))
    }
  }

  private handleClientExit(job: CodexJob, error: Error): void {
    if (terminalStatuses.has(job.status)) return

    void this.finish(job, 'failed', { error: error.message }).catch(finishError => {
      this.recordAsyncError(job, finishError)
      job.abortController.abort(error)
    })
  }

  private async handleServerRequest(
    job: CodexJob,
    message: JsonRpcMessage,
    client: CodexAppServerClient
  ): Promise<void> {
    const method = typeof message.method === 'string' ? message.method : ''
    if (message.id === undefined) return

    if (method === 'item/tool/requestUserInput') {
      job.pendingUserInput = {
        requestId: message.id,
        params: jsonObject(message.params)
      }
      await this.audit(job, 'server_request', 'request_user_input', jsonObject(message.params))
      await this.setStatus(job, 'waiting_on_user')
      return
    }

    if (approvalRequestMethod(method)) {
      await this.audit(job, 'server_request', 'approval_rejected', {
        method,
        params: jsonObject(message.params)
      })
      await client.respond(message.id, approvalRejection(method))
      await this.finish(job, 'failed', { error: `Codex requested approval (${method}); approvals are disabled` })
      await client.close()
      return
    }

    await client.respondError(message.id, -32601, `Ankole does not implement Codex server request ${method}`)
    await this.finish(job, 'failed', { error: `Unsupported Codex server request: ${method}` })
  }

  private async setStatus(job: CodexJob, status: CodexDelegationStatus): Promise<void> {
    await this.updateStatus(job, { status })
    job.status = status
    if (status === 'running' && !job.startedAtUnixMs) job.startedAtUnixMs = Date.now()
    await this.audit(job, status === 'running' ? 'process' : 'audit', `status_${status}`, {})
    this.notify(job)
  }

  private async finish(job: CodexJob, status: CodexDelegationStatus, details: JsonObject): Promise<void> {
    if (terminalStatuses.has(job.status)) return
    job.status = status
    job.completedAtUnixMs = Date.now()
    if (typeof details.error === 'string') job.error = details.error

    try {
      this.enqueueAudit(job, 'audit', `status_${status}`, details)
      await job.auditTail

      const auditError = job.auditError
      const finalStatus: CodexDelegationStatus = auditError && status === 'succeeded' ? 'failed' : status
      const finalDetails =
        auditError && status === 'succeeded'
          ? {
              error: `Codex audit failed: ${auditError.message}`,
              codex_turn_status: details.codex_turn_status ?? 'unknown'
            }
          : details

      if (finalStatus !== status) {
        job.status = finalStatus
        job.error = typeof finalDetails.error === 'string' ? finalDetails.error : job.error
      }

      await this.updateStatus(job, {
        status: finalStatus,
        result: finalStatus === 'succeeded' ? { ...details, output_text: job.outputText } : {},
        error: finalStatus === 'succeeded' ? {} : finalDetails,
        ...(job.codexThreadId ? { codex_thread_id: job.codexThreadId } : {})
      })
    } catch (error) {
      const normalized = error instanceof Error ? error : new Error(String(error))
      this.recordAsyncError(job, normalized)
      if (status === 'succeeded') {
        job.status = 'failed'
        job.error = `Codex finalization failed: ${normalized.message}`
      }
    } finally {
      this.notify(job)
    }
  }

  private async updateStatus(
    job: CodexJob,
    request: Omit<CodexDelegationStatusUpdateRequest, 'request_id' | 'delegation_id' | 'agent_uid'>
  ): Promise<void> {
    const response = await this.sendStatusUpdate(job, request)
    if ('code' in response) throw new Error(`Codex audit status rejected: ${response.code} ${response.message ?? ''}`)
  }

  private async sendStatusUpdate(
    job: CodexJob,
    request: Omit<CodexDelegationStatusUpdateRequest, 'request_id' | 'delegation_id' | 'agent_uid'>
  ): Promise<CodexDelegationResponse | CodexDelegationRejected> {
    const update = job.requesters.updateCodexDelegationStatus
    if (!update) throw new Error('Codex delegation status RPC is not configured')
    return update({
      request_id: `codex-status-${crypto.randomUUID()}`,
      delegation_id: job.delegationId,
      agent_uid: job.agentUid,
      ...request
    })
  }

  private async audit(
    job: CodexJob,
    direction: CodexDelegationEventAppendRequest['direction'],
    eventType: string,
    payload: JsonObject
  ): Promise<void> {
    this.enqueueAudit(job, direction, eventType, payload)
    await job.auditTail
    if (job.auditError) throw job.auditError
  }

  private enqueueAudit(
    job: CodexJob,
    direction: CodexDelegationEventAppendRequest['direction'],
    eventType: string,
    payload: JsonObject
  ): void {
    const append = job.requesters.appendCodexDelegationEvent
    if (!append) {
      job.auditError = new Error('Codex delegation event RPC is not configured')
      return
    }

    const seq = job.seq++
    job.auditTail = job.auditTail
      .then(async () => {
        const response = await append({
          request_id: `codex-event-${crypto.randomUUID()}`,
          delegation_id: job.delegationId,
          agent_uid: job.agentUid,
          seq,
          direction,
          event_type: eventType,
          payload,
          occurred_at: new Date().toISOString()
        })
        if (response && typeof response === 'object' && 'code' in response) {
          const rejected = response as { code?: unknown; message?: unknown }
          throw new Error(`Codex audit event rejected: ${String(rejected.code)} ${String(rejected.message ?? '')}`)
        }
      })
      .catch(error => {
        job.auditError = error instanceof Error ? error : new Error(String(error))
      })
  }

  private async flushAudit(job: CodexJob): Promise<void> {
    await job.auditTail
  }

  private recordAsyncError(job: CodexJob, error: unknown): void {
    const normalized = error instanceof Error ? error : new Error(String(error))
    job.auditError ??= normalized
    if (!job.error) job.error = normalized.message
  }

  private removeQueued(job: CodexJob): void {
    const queue = this.queuedByAgent.get(job.agentUid) ?? []
    this.queuedByAgent.set(
      job.agentUid,
      queue.filter(item => item.delegationId !== job.delegationId)
    )
  }

  private scheduleRequeue(job: CodexJob): void {
    if (terminalStatuses.has(job.status)) return
    job.status = 'queued'
    this.notify(job)

    setTimeout(() => {
      if (terminalStatuses.has(job.status)) return
      this.enqueue(job)
      this.pump(job.agentUid)
    }, queueRetryDelayMs)
  }

  private requireJob(delegationId: string): CodexJob {
    const job = this.jobs.get(delegationId)
    if (!job) throw new Error(`unknown Codex delegation: ${delegationId}`)
    return job
  }

  private notify(job: CodexJob): void {
    for (const waiter of job.waiters) waiter()
  }
}

export const codexDelegationManager = new CodexDelegationManager()

async function resolveConfigOverride(job: CodexJob) {
  const requester = job.requesters.requestAppConfigure
  if (!requester) return null

  const response = await requester({
    request_id: `app-configure-codex-${crypto.randomUUID()}`,
    agent_uid: job.agentUid,
    keys: [CodexConfigOverrideKey]
  })
  if ('code' in response) throw new Error(`Codex config override rejected: ${response.code} ${response.message ?? ''}`)

  return parseCodexConfigOverride(response.values[CodexConfigOverrideKey]?.value)
}

async function resolveAIGatewayKey(job: CodexJob): Promise<AIGatewayApiKeyResponse> {
  const response = await job.requesters.requestAIGatewayApiKey({
    request_id: `codex-ai-gateway-key-${crypto.randomUUID()}`,
    agent_uid: job.agentUid
  })
  if ('code' in response)
    throw new Error(`AIGateway API key rejected for Codex: ${response.code} ${response.message ?? ''}`)
  return response
}

function waitForJobChange(job: CodexJob, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) throw signal.reason ?? new DOMException('aborted', 'AbortError')

  return new Promise((resolvePromise, reject) => {
    const done = () => {
      cleanup()
      resolvePromise()
    }
    const abort = () => {
      cleanup()
      reject(signal?.reason ?? new DOMException('aborted', 'AbortError'))
    }
    const cleanup = () => {
      job.waiters.delete(done)
      signal?.removeEventListener('abort', abort)
    }
    job.waiters.add(done)
    signal?.addEventListener('abort', abort, { once: true })
  })
}

function snapshot(job: CodexJob): CodexDelegationSnapshot {
  return {
    delegation_id: job.delegationId,
    agent_uid: job.agentUid,
    session_id: job.sessionId,
    status: job.status,
    ...(job.codexThreadId ? { codex_thread_id: job.codexThreadId } : {}),
    ...(job.codexTurnId ? { codex_turn_id: job.codexTurnId } : {}),
    workdir: modelPath(job.workspaceRoot, job.workdir),
    queued_at_unix_ms: job.queuedAtUnixMs,
    ...(job.startedAtUnixMs ? { started_at_unix_ms: job.startedAtUnixMs } : {}),
    ...(job.completedAtUnixMs ? { completed_at_unix_ms: job.completedAtUnixMs } : {}),
    ...(job.outputText ? { output_text: job.outputText } : {}),
    ...(job.error ? { error: job.error } : {}),
    ...(job.pendingUserInput ? { waiting_on_user: job.pendingUserInput.params } : {}),
    ...(job.seq > 0 ? { last_event_seq: job.seq - 1 } : {}),
    ...(terminalStatuses.has(job.status)
      ? { result_ref: { type: 'codex_delegation', delegation_id: job.delegationId } }
      : {})
  }
}

function resolveCodexWorkdir(workspaceRoot: string, workdir?: string): string {
  const root = resolve(workspaceRoot)
  const candidate = !workdir
    ? root
    : workdir.startsWith('/workspace')
      ? resolve(root, workdir.slice('/workspace'.length).replace(/^\/+/, ''))
      : resolve(root, workdir)

  if (candidate !== root && !candidate.startsWith(`${root}/`)) {
    throw new Error('Codex workdir must stay inside the session workspace')
  }

  return candidate
}

function modelPath(workspaceRoot: string, path: string): string {
  const rel = relative(resolve(workspaceRoot), resolve(path))
  if (!rel || rel === '.') return '/workspace'
  return join('/workspace', rel).replaceAll('\\', '/')
}

function textInput(text: string): Array<JsonObject> {
  return [{ type: 'text', text, text_elements: [] }]
}

function jsonObject(value: unknown): JsonObject {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonObject) : {}
}

function jsonObjectOrEmpty(value: unknown): JsonObject {
  return jsonObject(value)
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}

function approvalRequestMethod(method: string): boolean {
  return method.endsWith('/requestApproval') || method === 'execCommandApproval' || method === 'applyPatchApproval'
}

function approvalRejection(method: string): JsonObject {
  if (method === 'execCommandApproval' || method === 'applyPatchApproval') return { decision: 'denied' }
  return { decision: 'decline' }
}

function userInputResponse(
  params: JsonObject,
  fallbackAnswer: string,
  suppliedAnswers?: Record<string, string | string[]>
): JsonObject {
  const questions = Array.isArray(params.questions) ? params.questions : []
  const answers: Record<string, { answers: string[] }> = {}

  for (const question of questions) {
    const questionObject = jsonObject(question)
    const id = stringValue(questionObject.id)
    if (!id) continue
    const supplied = suppliedAnswers?.[id]
    const values = Array.isArray(supplied) ? supplied : typeof supplied === 'string' ? [supplied] : [fallbackAnswer]
    answers[id] = { answers: values }
  }

  return { answers }
}
