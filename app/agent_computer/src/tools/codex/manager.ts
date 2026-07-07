import { jsonObject } from '@pleisto/active-support'
import { mkdirSync, rmSync } from 'node:fs'
import type { JsonObject } from '@pleisto/active-support'
import { errorMessage, toError } from '../../common/errors'
import { toWorkspacePath as modelPath } from '../../core/workspace-paths'
import {
  assertRpcResponse,
  isRpcRejected,
  rpcRejectedMessage,
  type CodexDelegationRejected,
  type CodexDelegationResponse,
  type CodexDelegationStatusUpdateRequest
} from '../../lanes/rpc_lane'
import { CodexAppServerClient, type JsonRpcMessage } from './app-server-client'
import { materializeCodexConfig } from './config'
import { CodexJobRecord } from './job'
import { JobQueue } from './job-queue'
import {
  approvalRejection,
  approvalRequestMethod,
  projectCodexNotification,
  stringValue,
  textInput,
  userInputResponse
} from './protocol'
import { resolveCodexRuntimeConfig } from './runtime-config'
import { codexAppServerSandboxSpec, resolveCodexWorkdir } from './sandbox'
import type { CodexDelegationSnapshot, CodexDelegationStatus, CodexSubmitOptions } from './types'
import { terminalStatuses } from './types'

export type {
  CodexDelegateRequest,
  CodexDelegationSnapshot,
  CodexDelegationStatus,
  CodexRuntimeRequesters,
  CodexSubmitOptions
} from './types'

const maxRunningPerAgent = 3
const queueRetryDelayMs = 1000

export class CodexDelegationManager {
  private jobs = new Map<string, CodexJobRecord>()
  private queue = new JobQueue<CodexJobRecord>({
    maxRunning: maxRunningPerAgent,
    getGroupId: job => job.agentUid,
    getJobId: job => job.delegationId,
    run: job => this.run(job),
    onError: (job, error) => {
      job.recordAsyncError(error)
    }
  })

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
        output_schema: jsonObject(opts.request.outputSchema),
        prompt_chars: opts.request.prompt.length
      }
    })

    assertRpcResponse<CodexDelegationResponse>(created, 'Codex audit create rejected')

    const job = new CodexJobRecord({
      delegationId: created.delegation_id,
      agentUid: opts.turnStart.turn.actor.agent_uid,
      sessionId: opts.turnStart.turn.actor.session_id,
      actorEventId: opts.turnStart.turn.actor_event_id,
      toolCallId: opts.toolCallId,
      workspaceRoot: opts.workspaceRoot,
      workdir,
      prompt: opts.request.prompt,
      outputSchema: opts.request.outputSchema,
      requesters: opts.requesters
    })

    this.jobs.set(job.delegationId, job)
    await job.audit.record('queue', 'queued', { workdir: modelPath(job.workspaceRoot, job.workdir) })
    this.queue.enqueue(job)
    job.notify()
    return job.snapshot()
  }

  get(delegationId: string): CodexDelegationSnapshot | null {
    const job = this.jobs.get(delegationId)
    return job ? job.snapshot() : null
  }

  async wait(delegationId: string, signal?: AbortSignal): Promise<CodexDelegationSnapshot> {
    const job = this.requireJob(delegationId)
    return job.wait(signal)
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
      await job.audit.record('tool', 'user_input_answered', { response })
      job.pendingUserInput = undefined
      await this.setStatus(job, 'running')
      return job.snapshot()
    }

    if (!job.codexTurnId) throw new Error('Codex delegation does not have an active turn')

    await job.client.request('turn/steer', {
      threadId: job.codexThreadId,
      expectedTurnId: job.codexTurnId,
      input: textInput(text)
    })
    await job.audit.record('tool', 'turn_steer', { text })
    return job.snapshot()
  }

  async stop(delegationId: string): Promise<CodexDelegationSnapshot> {
    const job = this.requireJob(delegationId)

    if (job.status === 'queued') {
      this.queue.remove(job)
      await this.finish(job, 'stopped', { reason: 'stopped_before_start' })
      return job.snapshot()
    }

    if (job.client && job.codexThreadId && job.codexTurnId) {
      await job.client.request('turn/interrupt', {
        threadId: job.codexThreadId,
        turnId: job.codexTurnId
      })
    }
    job.abortController.abort(new DOMException('codex delegation stopped', 'AbortError'))
    await this.finish(job, 'stopped', { reason: 'stopped' })
    return job.snapshot()
  }

  private async run(job: CodexJobRecord): Promise<void> {
    try {
      const acquired = await this.acquireRunningSlot(job)
      if (!acquired) return
      await this.runCodex(job)
    } catch (error) {
      if (!terminalStatuses.has(job.status)) {
        await this.finish(job, job.abortController.signal.aborted ? 'stopped' : 'failed', {
          error: errorMessage(error)
        })
      }
    } finally {
      if (terminalStatuses.has(job.status)) await job.client?.close()
      if (terminalStatuses.has(job.status) && job.cleanupRoot) {
        rmSync(job.cleanupRoot, { recursive: true, force: true })
        job.cleanupRoot = undefined
      }
      await job.audit.flush()
    }
  }

  private async acquireRunningSlot(job: CodexJobRecord): Promise<boolean> {
    const response = await this.sendStatusUpdate(job, { status: 'running' })

    if (isRpcRejected(response)) {
      if (response.code === 'codex_agent_running_limit_exceeded') {
        await job.audit.record('queue', 'global_running_limit_deferred', {
          max_running_per_agent: maxRunningPerAgent,
          message: response.message ?? 'Codex delegation remains queued'
        })
        this.scheduleRequeue(job)
        return false
      }

      throw new Error(rpcRejectedMessage('Codex audit status rejected', response))
    }

    job.status = 'running'
    if (!job.startedAtUnixMs) job.startedAtUnixMs = Date.now()
    await job.audit.record('process', 'status_running', {})
    job.notify()
    return true
  }

  private async runCodex(job: CodexJobRecord): Promise<void> {
    const runtimeConfig = await resolveCodexRuntimeConfig({
      agentUid: job.agentUid,
      requesters: job.requesters
    })
    const materialized = materializeCodexConfig({
      workspaceRoot: job.workspaceRoot,
      delegationId: job.delegationId,
      override: runtimeConfig.override,
      aiGatewayKey: runtimeConfig.aiGatewayKey
    })
    job.cleanupRoot = materialized.cleanupRoot

    await job.audit.record('process', 'config_materialized', {
      mode: runtimeConfig.override?.mode ?? 'aigateway',
      codex_home: modelPath(job.workspaceRoot, materialized.codexHome),
      has_auth_json: runtimeConfig.override?.auth_json !== undefined
    })

    const sandbox = codexAppServerSandboxSpec({
      workspaceRoot: job.workspaceRoot,
      workdir: job.workdir,
      materialized
    })
    const client = new CodexAppServerClient({
      cwd: sandbox.cwd,
      env: sandbox.env,
      commandArgv: sandbox.commandArgv,
      audit: (direction, message) => job.audit.enqueue(direction, 'json_rpc', { message }),
      onExit: error => this.handleClientExit(job, error),
      onNotification: message => this.handleNotification(job, message),
      onServerRequest: async (message, appServer) => {
        try {
          await this.handleServerRequest(job, message, appServer)
        } catch (error) {
          job.recordAsyncError(error)
          await this.finish(job, 'failed', {
            error: errorMessage(error)
          })
        }
      }
    })
    job.client = client

    await client.initialize()
    const threadStart = (await client.request('thread/start', {
      cwd: sandbox.codexCwd,
      approvalPolicy: 'never',
      sandbox: 'danger-full-access',
      threadSource: 'ankole',
      ...(runtimeConfig.modelOverride ? { model: runtimeConfig.modelOverride } : {})
    })) as JsonObject

    const thread = jsonObject(threadStart.thread)
    job.codexThreadId = stringValue(thread.id)
    if (!job.codexThreadId) throw new Error('codex app-server did not return a thread id')
    await this.updateStatus(job, { status: 'running', codex_thread_id: job.codexThreadId })

    const turnStart = (await client.request('turn/start', {
      threadId: job.codexThreadId,
      input: textInput(job.prompt),
      cwd: sandbox.codexCwd,
      approvalPolicy: 'never',
      sandboxPolicy: { type: 'dangerFullAccess' },
      ...(runtimeConfig.modelOverride ? { model: runtimeConfig.modelOverride } : {}),
      ...(job.outputSchema ? { outputSchema: job.outputSchema } : {})
    })) as JsonObject
    const turn = jsonObject(turnStart.turn)
    job.codexTurnId = stringValue(turn.id)

    while (!terminalStatuses.has(job.status)) {
      await job.waitForChange(job.abortController.signal)
    }
  }

  private handleNotification(job: CodexJobRecord, message: JsonRpcMessage): void {
    const projection = projectCodexNotification(message)

    if (projection.type === 'stderr') {
      job.audit.enqueue('process', 'stderr', projection.params)
      return
    }

    if (projection.type === 'turn_started') {
      job.codexTurnId = projection.turnId || job.codexTurnId
      return
    }

    if (projection.type === 'agent_delta') {
      job.outputText += projection.delta
      return
    }

    if (projection.type === 'turn_completed') {
      void this.finish(job, projection.terminalStatus, {
        codex_turn_status: projection.codexTurnStatus,
        output_text: job.outputText
      }).catch(error => job.recordAsyncError(error))
    }
  }

  private handleClientExit(job: CodexJobRecord, error: Error): void {
    if (terminalStatuses.has(job.status)) return

    void this.finish(job, 'failed', { error: error.message }).catch(finishError => {
      job.recordAsyncError(finishError)
      job.abortController.abort(error)
    })
  }

  private async handleServerRequest(
    job: CodexJobRecord,
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
      await job.audit.record('server_request', 'request_user_input', jsonObject(message.params))
      await this.setStatus(job, 'waiting_on_user')
      return
    }

    if (approvalRequestMethod(method)) {
      await job.audit.record('server_request', 'approval_rejected', {
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

  private async setStatus(job: CodexJobRecord, status: CodexDelegationStatus): Promise<void> {
    await this.updateStatus(job, { status })
    job.status = status
    if (status === 'running' && !job.startedAtUnixMs) job.startedAtUnixMs = Date.now()
    await job.audit.record(status === 'running' ? 'process' : 'audit', `status_${status}`, {})
    job.notify()
  }

  private async finish(job: CodexJobRecord, status: CodexDelegationStatus, details: JsonObject): Promise<void> {
    if (terminalStatuses.has(job.status)) return
    job.status = status
    job.completedAtUnixMs = Date.now()
    if (typeof details.error === 'string') job.error = details.error

    try {
      job.audit.enqueue('audit', `status_${status}`, details)
      await job.audit.flush()

      const auditError = job.audit.failure
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
      const normalized = toError(error)
      job.recordAsyncError(normalized)
      if (status === 'succeeded') {
        job.status = 'failed'
        job.error = `Codex finalization failed: ${normalized.message}`
      }
    } finally {
      job.notify()
    }
  }

  private async updateStatus(
    job: CodexJobRecord,
    request: Omit<CodexDelegationStatusUpdateRequest, 'request_id' | 'delegation_id' | 'agent_uid'>
  ): Promise<void> {
    const response = await this.sendStatusUpdate(job, request)
    assertRpcResponse<CodexDelegationResponse>(response, 'Codex audit status rejected')
  }

  private async sendStatusUpdate(
    job: CodexJobRecord,
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

  private scheduleRequeue(job: CodexJobRecord): void {
    if (terminalStatuses.has(job.status)) return
    job.status = 'queued'
    job.notify()

    this.queue.requeueLater(job, queueRetryDelayMs, () => !terminalStatuses.has(job.status))
  }

  private requireJob(delegationId: string): CodexJobRecord {
    const job = this.jobs.get(delegationId)
    if (!job) throw new Error(`unknown Codex delegation: ${delegationId}`)
    return job
  }
}

export const codexDelegationManager = new CodexDelegationManager()
