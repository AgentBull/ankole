import { jsonObject, type JsonObject as JSONObject } from '@agentbull/active-support'
import { Buffer } from 'node:buffer'
import { existsSync, realpathSync, statSync } from 'node:fs'
import { resolve } from 'node:path'
import { errorMessage, toError } from '../../../common/errors'
import { compareCodePointStrings } from '../../../common/ordering'
import { isRuntimeFabricTransportError } from '../../../fabric/fabric'
import type { BackgroundAgentJobResponse } from '../../../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCTimeoutError } from '../../../lanes/rpc-lane'
import type { JobTurnRef, TurnStart, TurnSteerUpdate } from '../../../lanes/session-lane'
import { boundedBackgroundAgentJobPaths, type BackgroundAgentJobPathHandoff } from '../../background-agent-job-handoff'
import { pathIsWithin } from '../../path-boundary'
import type { AgentLoopLogger } from '../../types'
import type { CodexJobOptions } from '../options'
import { stringValue, textInput } from '../protocol'
import type { CodexAppServerClient } from '../runtime/app-server-client'
import type { CodexCredentialPoolExhaustion } from './recovery-policy'
import { skillDisabledNotice } from './skill-usage'
import { changedWorkspacePaths, snapshotWorkspace, type WorkspaceSnapshot } from './workspace-snapshot'

/** One `thread/compact/start` in flight; `turnID` arrives with the Turn's `turn/started`. */
export type CompactionHandshake = {
  threadID: string
  turnID?: string
  resolve(): void
  reject(error: Error): void
}

export type ContinuationSourceContext = {
  task?: string | undefined
  finalReport?: string | undefined
}

/**
 * Fetches the terminal source Job's task and final report for a continued
 * Job whose thread context could not be restored. Both facts are durable on
 * the source Job row; absence of either keeps the rebuild honest instead of
 * blocking it.
 */
export async function fetchContinuationSourceContext(input: {
  rpc: CodexJobOptions['rpc']
  jobTurn: JobTurnRef
  jobID: string
  sourceJobID: string
  abortSignal?: AbortSignal
  logger?: AgentLoopLogger
}): Promise<ContinuationSourceContext | undefined> {
  const { rpc, jobTurn, jobID, sourceJobID, abortSignal, logger } = input
  try {
    let offset = 0
    let task: string | undefined
    const report: string[] = []
    for (;;) {
      const source = await rpc(
        'background_agent_job.get',
        { jobId: sourceJobID, resultOffset: String(offset) },
        { jobTurn },
        { retryOnDisconnect: true }
      )
      task ??= stringValue(source.task)
      report.push(source.resultOutputText)
      offset += Buffer.byteLength(source.resultOutputText, 'utf8')
      const total = Number(source.resultOutputTotalBytes)
      if (!Number.isSafeInteger(total) || total < offset) throw new Error('Invalid source Job result size')
      if (offset === total) break
      if (!source.resultOutputText) throw new Error('Source Job result window did not advance')
    }
    return { task, finalReport: stringValue(report.join('')) }
  } catch (error) {
    logger?.warning(
      'worker.codex_continuation_source_unavailable',
      'the continued Job could not read its source Job for the rebuilt thread seed',
      {
        job_id: jobID,
        source_job_id: sourceJobID,
        error: toError(error)
      }
    )
    if (isRuntimeFabricTransportError(error) || error instanceof RPCTimeoutError || abortSignal?.aborted) {
      throw error
    }
    return undefined
  }
}

export async function snapshotJobWorkspace(
  root: string,
  jobID: string,
  logger?: AgentLoopLogger
): Promise<WorkspaceSnapshot | undefined> {
  try {
    const outcome = await snapshotWorkspace(root)
    if ('skipped' in outcome) {
      logger?.warning(
        'worker.files_changed_snapshot_skipped',
        'the Job Workspace snapshot exceeded its bound; files_changed keeps only the Codex diff',
        { job_id: jobID, job_workspace: root, reason: outcome.skipped }
      )
      return undefined
    }
    return outcome.files
  } catch (error) {
    logger?.warning(
      'worker.files_changed_snapshot_failed',
      'the Job Workspace snapshot failed; files_changed keeps only the Codex diff',
      { job_id: jobID, job_workspace: root, error: toError(error) }
    )
    return undefined
  }
}

/**
 * Codex reports only the files its own tools changed. A file that a shell
 * command or a child thread wrote shows up as a workspace change since the
 * attempt started. The result names each source that contributed.
 */
export async function collectJobFilesChanged(input: {
  root: string
  jobID: string
  codexDiff: BackgroundAgentJobPathHandoff
  beforeSnapshot: WorkspaceSnapshot | undefined
  logger?: AgentLoopLogger
}): Promise<{ handoff: BackgroundAgentJobPathHandoff; sources: string[] }> {
  const { root, jobID, codexDiff, beforeSnapshot, logger } = input
  const afterSnapshot = beforeSnapshot ? await snapshotJobWorkspace(root, jobID, logger) : undefined
  const workspaceChanges =
    beforeSnapshot && afterSnapshot
      ? boundedBackgroundAgentJobPaths(changedWorkspacePaths(beforeSnapshot, afterSnapshot))
      : undefined
  if (!workspaceChanges) {
    return {
      handoff: codexDiff,
      sources: [...(codexDiff.total_count > 0 ? ['codex_diff'] : []), 'workspace_snapshot_skipped']
    }
  }
  const handoff = boundedBackgroundAgentJobPaths(new Set([...codexDiff.paths, ...workspaceChanges.paths]), {
    totalCount: Math.max(codexDiff.total_count, workspaceChanges.total_count),
    truncated: codexDiff.truncated || workspaceChanges.truncated
  })
  if (handoff.truncated) {
    logger?.info('worker.files_changed_truncated', 'the Job result lists a bounded subset of changed files', {
      job_id: jobID,
      total_count: handoff.total_count,
      listed_count: handoff.paths.length
    })
  }
  return {
    handoff,
    sources: [
      ...(codexDiff.total_count > 0 ? ['codex_diff'] : []),
      ...(workspaceChanges.total_count > 0 ? ['workspace_snapshot'] : [])
    ]
  }
}

export function updateOriginalHumanRequestInstructions(
  currentInstructions: string,
  previousRequest: string | undefined,
  update: TurnSteerUpdate
): { instructions: string; originalHumanRequest: string } | undefined {
  if (!update.signal) return undefined
  const request = stringValue(jsonObject(update.signal.payload_json).original_human_request)
  if (!request || request === previousRequest) return undefined
  const base =
    previousRequest && currentInstructions.endsWith(previousRequest)
      ? currentInstructions.slice(0, -previousRequest.length).trimEnd()
      : currentInstructions
  return {
    instructions: [base, request].filter(Boolean).join('\n\n'),
    originalHumanRequest: request
  }
}

export function turnInput(turnStart: TurnStart, job: BackgroundAgentJobResponse): string {
  if (turnStart.signal.type === 'command.steer') {
    const command = jsonObject(jsonObject(jsonObject(turnStart.signal.payload_json).data).command)
    const message = stringValue(command.argsText)
    if (!message) throw new Error('BackgroundAgentJob message command is missing argsText')
    const originalRequest = stringValue(jsonObject(turnStart.signal.payload_json).original_human_request)
    return originalRequest ? `${originalRequest}\n\nDelegated message:\n${message}` : message
  }

  if (job.attempts > 1 && job.runtimeThreadId) {
    return 'Continue the Job task. Re-check the acceptance criteria in the original task before finishing.'
  }

  return job.task
}

export function ownerVisibleArtifactPaths(projectRoot: string, filesChanged: string[]): string[] {
  const artifacts = new Set<string>()
  for (const path of filesChanged) {
    const artifact = ownerVisibleArtifactPath(projectRoot, path)
    if (artifact) artifacts.add(artifact)
  }
  return [...artifacts].sort(compareCodePointStrings)
}

export function artifactDiscoveryRoots(projectRoot: string): BackgroundAgentJobPathHandoff {
  return boundedBackgroundAgentJobPaths([projectRoot])
}

function ownerVisibleArtifactPath(projectRoot: string, changedPath: string): string | undefined {
  const hostPath = changedPath.startsWith('/') ? resolve(changedPath) : resolve(projectRoot, changedPath)
  if (!existsSync(hostPath)) return undefined

  try {
    const realRoot = realpathSync(projectRoot)
    const realPath = realpathSync(hostPath)
    if (!pathIsWithin(realRoot, realPath) || !statSync(realPath).isFile()) return undefined
    return realPath
  } catch {
    return undefined
  }
}

export function turnClientUserMessageID(turnStart: TurnStart): string | undefined {
  if (turnStart.signal.type === 'command.steer') return turnStart.signal.signal_id
  return undefined
}

export function retryContinuationInput(): string {
  return 'Continue the Job task after the transient runtime error. Inspect the current workspace before repeating any side effect, then re-check the original acceptance criteria.'
}

export function compactContinuationInput(task: string): string {
  return [
    'Context was compacted near the window limit. Stop open-ended exploration, inspect the deliverables already materialized in the workspace or Drive, and finish or verify the remaining requirements.',
    'Reconcile every acceptance criterion verbatim against the original task below; if any criterion cannot be satisfied within the remaining budget, state `Outcome: incomplete` with saved deliverable paths and exact unmet items.',
    `Original task:\n${task}`
  ].join('\n\n')
}

export function recreatedThreadInput(
  job: BackgroundAgentJobResponse,
  continuation: string,
  source?: ContinuationSourceContext
): string {
  const priorAttempts = job.attemptHistory?.length
    ? `\n\nBounded history from prior execution attempts:\n${JSON.stringify(job.attemptHistory, null, 2)}`
    : ''
  const sourceContext = source?.task
    ? `\n\nThis Job continues terminal Job ${job.continuedFromJobId}. Its original task:\n${source.task}\n\nIts final report:\n${source.finalReport ?? '(the source Job recorded no final report)'}`
    : ''
  return `${job.task}\n\nThe previous Codex thread could not be resumed. Inspect the existing working directory and continue from durable artifacts.${sourceContext}${priorAttempts}\n\nCurrent continuation instructions:\n${continuation}\n\nRe-check every acceptance criterion before finishing.`.trim()
}

export async function steerActiveTurn(
  client: CodexAppServerClient,
  threadID: string,
  turnID: string,
  updates: TurnSteerUpdate[],
  acceptsOutcome: () => boolean,
  onTrajectorySteering: (eventID: string, text: string, update: TurnSteerUpdate) => Promise<void>,
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
): Promise<void> {
  for (const update of updates) {
    const event = update.signal
    if (!event) continue
    const command = jsonObject(jsonObject(jsonObject(event.payload_json).data).command)
    const message = stringValue(command.argsText)
    if (!message) continue
    const originalRequest = stringValue(jsonObject(event.payload_json).original_human_request)
    const text = originalRequest ? `${originalRequest}\n\nDelegated message:\n${message}` : message
    try {
      await client.request('turn/steer', {
        ['threadId']: threadID,
        ['expectedTurnId']: turnID,
        ['clientUserMessageId']: event.signal_id,
        input: textInput(text)
      })
      if (!acceptsOutcome()) continue
      await onTrajectorySteering(event.signal_id, text, update)
      await onSteeringApplied?.(update)
    } catch (error) {
      if (!acceptsOutcome()) continue
      if (!isSteerCompletionRace(error)) throw new BackgroundAgentJobMessageDeliveryError(error)
    }
  }
}

export async function steerDisabledSkills(
  client: CodexAppServerClient,
  threadID: string,
  turnID: string,
  skillNames: string[],
  acceptsOutcome: () => boolean,
  onApplied: (name: string, eventID: string, text: string) => Promise<void>
): Promise<void> {
  for (const name of skillNames) {
    const eventID = `skill-disabled:${name}`
    const text = skillDisabledNotice(name)
    try {
      await client.request('turn/steer', {
        ['threadId']: threadID,
        ['expectedTurnId']: turnID,
        ['clientUserMessageId']: eventID,
        input: textInput(text)
      })
      if (acceptsOutcome()) await onApplied(name, eventID, text)
    } catch (error) {
      if (!acceptsOutcome()) continue
      if (!isSteerCompletionRace(error)) throw new BackgroundAgentJobMessageDeliveryError(error)
    }
  }
}

function isSteerCompletionRace(error: unknown): boolean {
  return /^(?:no active turn to steer|(?:turn\s+)?already (?:completed|finished)|turn .* (?:has )?(?:completed|finished))$/i.test(
    errorMessage(error).trim()
  )
}

class CodexJobTransientError extends Error {
  readonly code = 'codex_job_transient'
  readonly retryable = true

  constructor(cause: unknown) {
    super(
      `Codex transient runtime failure requires durable retry: ${stringValue(jsonObject(cause).message) ?? errorMessage(cause)}`,
      { cause: cause instanceof Error ? cause : undefined }
    )
    this.name = 'CodexJobTransientError'
  }
}

/**
 * An app-server internal failure is infrastructure, not the task failing: the
 * process (or its agent loop) died and a replacement serves the next attempt.
 * The runtime-exception code keeps the control plane's retry accounting on the
 * uncharged infrastructure ladder.
 */
class CodexRuntimeInternalError extends Error {
  readonly code = 'background_agent_job_runtime_exception'
  readonly retryable = true

  constructor(cause: unknown) {
    super(
      `Codex app-server internal failure requires durable retry: ${stringValue(jsonObject(cause).message) ?? errorMessage(cause)}`,
      { cause: cause instanceof Error ? cause : undefined }
    )
    this.name = 'CodexRuntimeInternalError'
  }
}

export function durableRetryError(cause: JSONObject): Error {
  const message = `${stringValue(cause.message) ?? ''}`.toLowerCase()
  if (cause.code === -32603 || message.includes('agent loop died')) return new CodexRuntimeInternalError(cause)
  return new CodexJobTransientError(cause)
}

export class CodexTurnNoProgressError extends Error {
  readonly code = 'codex_turn_no_progress'
  readonly retryable = true

  constructor(timeoutMs: number) {
    super(`Codex turn produced no runtime progress within ${timeoutMs}ms after turn/start`)
    this.name = 'CodexTurnNoProgressError'
  }
}

export class CodexCredentialPoolExhaustedError extends Error {
  readonly code = 'credential_pool_exhausted'
  readonly retryable = true
  readonly status = 429
  readonly retryAt: string | undefined
  readonly details: JSONObject

  constructor(exhaustion: CodexCredentialPoolExhaustion, cause: JSONObject) {
    const retrySuffix = exhaustion.retryAt ? ` retry_at=${exhaustion.retryAt}` : ''
    super(`AIGateway credential pool exhausted.${retrySuffix}`, {
      cause: new Error(stringValue(cause.message) ?? 'Codex reported an exhausted credential pool')
    })
    this.name = 'CodexCredentialPoolExhaustedError'
    this.retryAt = exhaustion.retryAt
    this.details = exhaustion.retryAt ? { retry_at: exhaustion.retryAt } : {}
  }
}

export class BackgroundAgentJobMessageDeliveryError extends Error {
  readonly code = 'background_agent_job_steer_delivery_failed'
  readonly retryable = true

  constructor(cause: unknown) {
    super(`BackgroundAgentJob steer delivery failed: ${errorMessage(cause)}`, {
      cause: cause instanceof Error ? cause : undefined
    })
    this.name = 'BackgroundAgentJobMessageDeliveryError'
  }
}

export function abortReason(signal?: AbortSignal): string {
  if (!signal?.aborted) return 'stopped'
  return signal.reason instanceof Error ? signal.reason.message : String(signal.reason ?? 'stopped')
}
