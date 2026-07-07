import type { JsonObject } from '@pleisto/active-support'
import { toError } from '../../common/errors'
import { toWorkspacePath as modelPath } from '../../core/workspace-paths'
import type { CodexAppServerClient } from './app-server-client'
import { AuditPipeline } from './audit'
import type { CodexDelegationSnapshot, CodexDelegationStatus, CodexRuntimeRequesters } from './types'
import { terminalStatuses } from './types'

export type PendingUserInput = {
  requestId: string | number
  params: JsonObject
}

export type CodexJobInit = {
  delegationId: string
  agentUid: string
  sessionId: string
  actorEventId: string
  toolCallId: string
  workspaceRoot: string
  workdir: string
  prompt: string
  outputSchema?: unknown
  requesters: CodexRuntimeRequesters
}

export class CodexJobRecord {
  readonly delegationId: string
  readonly agentUid: string
  readonly sessionId: string
  readonly actorEventId: string
  readonly toolCallId: string
  readonly workspaceRoot: string
  readonly workdir: string
  readonly prompt: string
  readonly outputSchema?: unknown
  readonly requesters: CodexRuntimeRequesters
  readonly queuedAtUnixMs = Date.now()
  readonly waiters = new Set<() => void>()
  readonly abortController = new AbortController()
  readonly audit: AuditPipeline

  status: CodexDelegationStatus = 'queued'
  startedAtUnixMs?: number
  completedAtUnixMs?: number
  codexThreadId?: string
  codexTurnId?: string
  outputText = ''
  error?: string
  pendingUserInput?: PendingUserInput
  client?: CodexAppServerClient
  cleanupRoot?: string

  constructor(init: CodexJobInit) {
    this.delegationId = init.delegationId
    this.agentUid = init.agentUid
    this.sessionId = init.sessionId
    this.actorEventId = init.actorEventId
    this.toolCallId = init.toolCallId
    this.workspaceRoot = init.workspaceRoot
    this.workdir = init.workdir
    this.prompt = init.prompt
    this.outputSchema = init.outputSchema
    this.requesters = init.requesters
    this.audit = new AuditPipeline({
      delegationId: init.delegationId,
      agentUid: init.agentUid,
      append: init.requesters.appendCodexDelegationEvent
    })
  }

  snapshot(): CodexDelegationSnapshot {
    return {
      delegation_id: this.delegationId,
      agent_uid: this.agentUid,
      session_id: this.sessionId,
      status: this.status,
      ...(this.codexThreadId ? { codex_thread_id: this.codexThreadId } : {}),
      ...(this.codexTurnId ? { codex_turn_id: this.codexTurnId } : {}),
      workdir: modelPath(this.workspaceRoot, this.workdir),
      queued_at_unix_ms: this.queuedAtUnixMs,
      ...(this.startedAtUnixMs ? { started_at_unix_ms: this.startedAtUnixMs } : {}),
      ...(this.completedAtUnixMs ? { completed_at_unix_ms: this.completedAtUnixMs } : {}),
      ...(this.outputText ? { output_text: this.outputText } : {}),
      ...(this.error ? { error: this.error } : {}),
      ...(this.pendingUserInput ? { waiting_on_user: this.pendingUserInput.params } : {}),
      ...(this.audit.lastSeq !== undefined ? { last_event_seq: this.audit.lastSeq } : {}),
      ...(terminalStatuses.has(this.status)
        ? { result_ref: { type: 'codex_delegation', delegation_id: this.delegationId } }
        : {})
    }
  }

  async wait(signal?: AbortSignal): Promise<CodexDelegationSnapshot> {
    while (!terminalStatuses.has(this.status) && this.status !== 'waiting_on_user') {
      await this.waitForChange(signal)
    }
    return this.snapshot()
  }

  waitForChange(signal?: AbortSignal): Promise<void> {
    return waitForJobChange(this, signal)
  }

  notify(): void {
    for (const waiter of this.waiters) waiter()
  }

  recordAsyncError(error: unknown): void {
    const normalized = toError(error)
    this.audit.recordError(normalized)
    if (!this.error) this.error = normalized.message
  }
}

function waitForJobChange(job: CodexJobRecord, signal?: AbortSignal): Promise<void> {
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
