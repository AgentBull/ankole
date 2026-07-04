import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import type { CodexRuntimeRequesters } from './manager'
import { codexDelegationManager, type CodexDelegationSnapshot } from './manager'

const CodexDelegateParams = z.object({
  action: z.enum(['run', 'start', 'status', 'steer', 'stop']).describe('Codex delegation action.'),
  prompt: z.string().min(1).describe('Task prompt for run/start, or steer text for steer.').optional(),
  delegation_id: z.string().min(1).describe('Delegation id for status/steer/stop.').optional(),
  workdir: z.string().describe('Workspace-relative path or /workspace path for Codex to use.').optional(),
  timeout_seconds: z
    .number()
    .int()
    .positive()
    .max(24 * 60 * 60)
    .optional(),
  output_schema: z
    .record(z.string(), z.unknown())
    .describe('Optional JSON Schema for the final Codex answer.')
    .optional(),
  answers: z
    .record(z.string(), z.union([z.string(), z.array(z.string())]))
    .describe('Answers keyed by Codex requestUserInput question id for steer.')
    .optional()
})

type CodexDelegateParams = z.output<typeof CodexDelegateParams>

export type CodexDelegateToolOptions = CodexRuntimeRequesters & {
  turnStart: TurnStart
  workspaceRoot: string
}

const DESCRIPTION = [
  'Delegate coding work to a nested OpenAI Codex app-server agent running inside this Agent Computer.',
  'Use for substantial code investigation, edits, tests, or self-iteration where a coding agent should work in the repo and report back.',
  '',
  'Actions:',
  '- run: start Codex and wait until it succeeds/fails/times out or needs user input.',
  '- start: enqueue a background Codex task and return a delegation_id immediately.',
  '- status: inspect a known delegation.',
  '- steer: answer a Codex question or steer an active Codex turn.',
  '- stop: cancel a queued or running delegation.',
  '',
  'Codex is always yolo/no-approval in this Ankole phase. If Codex asks for an approval, the delegation fails closed and the full trajectory is audited.'
].join('\n')

export function createCodexDelegateTool(
  opts: CodexDelegateToolOptions
): AgentTool<typeof CodexDelegateParams, CodexDelegationSnapshot> {
  return {
    name: 'codex_delegate',
    description: DESCRIPTION,
    schema: CodexDelegateParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(toolCallId, params, signal): Promise<AgentToolResult<CodexDelegationSnapshot>> {
      const result = await executeCodexDelegate(toolCallId, params, opts, signal)
      return {
        content: [{ type: 'text', text: modelVisibleResult(result) }],
        details: result
      }
    }
  }
}

async function executeCodexDelegate(
  toolCallId: string,
  params: CodexDelegateParams,
  opts: CodexDelegateToolOptions,
  signal?: AbortSignal
): Promise<CodexDelegationSnapshot> {
  switch (params.action) {
    case 'run': {
      const prompt = requiredPrompt(params)
      const snapshot = await codexDelegationManager.submit({
        turnStart: opts.turnStart,
        workspaceRoot: opts.workspaceRoot,
        toolCallId,
        request: {
          prompt,
          workdir: params.workdir,
          timeoutSeconds: params.timeout_seconds,
          outputSchema: params.output_schema
        },
        requesters: opts,
        signal
      })
      return codexDelegationManager.wait(snapshot.delegation_id, signal)
    }

    case 'start':
      return codexDelegationManager.submit({
        turnStart: opts.turnStart,
        workspaceRoot: opts.workspaceRoot,
        toolCallId,
        request: {
          prompt: requiredPrompt(params),
          workdir: params.workdir,
          timeoutSeconds: params.timeout_seconds,
          outputSchema: params.output_schema
        },
        requesters: opts,
        signal
      })

    case 'status':
      return statusSnapshot(params.delegation_id, opts)

    case 'steer':
      return codexDelegationManager.steer(requiredDelegationId(params), requiredPrompt(params), params.answers)

    case 'stop':
      return codexDelegationManager.stop(requiredDelegationId(params))
  }
}

function requiredPrompt(params: CodexDelegateParams): string {
  const prompt = params.prompt?.trim()
  if (!prompt) throw new Error(`${params.action} requires prompt`)
  return prompt
}

function requiredDelegationId(params: CodexDelegateParams): string {
  if (!params.delegation_id) throw new Error(`${params.action} requires delegation_id`)
  return params.delegation_id
}

async function statusSnapshot(
  delegationId: string | undefined,
  opts: CodexDelegateToolOptions
): Promise<CodexDelegationSnapshot> {
  if (!delegationId) throw new Error('status requires delegation_id')
  const snapshot = codexDelegationManager.get(delegationId)
  if (snapshot) return snapshot

  const getStatus = opts.getCodexDelegationStatus
  if (!getStatus) throw new Error(`unknown Codex delegation: ${delegationId}`)

  const response = await getStatus({
    request_id: `codex-status-read-${crypto.randomUUID()}`,
    delegation_id: delegationId,
    agent_uid: opts.turnStart.turn.actor.agent_uid
  })
  if ('code' in response) throw new Error(`Codex status rejected: ${response.code} ${response.message ?? ''}`)

  return snapshotFromResponse(response)
}

function modelVisibleResult(snapshot: CodexDelegationSnapshot): string {
  const lines = [
    `codex delegation ${snapshot.delegation_id}`,
    `status: ${snapshot.status}`,
    `workdir: ${snapshot.workdir}`
  ]
  if (snapshot.codex_thread_id) lines.push(`codex_thread_id: ${snapshot.codex_thread_id}`)
  if (snapshot.codex_turn_id) lines.push(`codex_turn_id: ${snapshot.codex_turn_id}`)
  if (snapshot.waiting_on_user) lines.push(`waiting_on_user: ${JSON.stringify(snapshot.waiting_on_user)}`)
  if (snapshot.output_text) lines.push(`output:\n${snapshot.output_text}`)
  if (snapshot.error) lines.push(`error: ${snapshot.error}`)
  return lines.join('\n')
}

function snapshotFromResponse(response: {
  delegation_id: string
  agent_uid: string
  session_id: string
  status: string
  codex_thread_id?: string
  workdir?: string
  queued_at?: string
  started_at?: string
  completed_at?: string
  result?: Record<string, unknown>
  error?: Record<string, unknown>
  last_event_seq?: number
  result_ref?: Record<string, unknown>
}): CodexDelegationSnapshot {
  const error =
    response.error && typeof response.error.error === 'string'
      ? response.error.error
      : response.error && Object.keys(response.error).length > 0
        ? JSON.stringify(response.error)
        : undefined
  const outputText =
    response.result && typeof response.result.output_text === 'string' ? response.result.output_text : undefined

  return {
    delegation_id: response.delegation_id,
    agent_uid: response.agent_uid,
    session_id: response.session_id,
    status: response.status as CodexDelegationSnapshot['status'],
    ...(response.codex_thread_id ? { codex_thread_id: response.codex_thread_id } : {}),
    workdir: response.workdir ?? '/workspace',
    queued_at_unix_ms: isoToUnixMs(response.queued_at),
    ...(response.started_at ? { started_at_unix_ms: isoToUnixMs(response.started_at) } : {}),
    ...(response.completed_at ? { completed_at_unix_ms: isoToUnixMs(response.completed_at) } : {}),
    ...(outputText ? { output_text: outputText } : {}),
    ...(error ? { error } : {}),
    ...(response.last_event_seq !== undefined ? { last_event_seq: response.last_event_seq } : {}),
    ...(response.result_ref ? { result_ref: response.result_ref } : {})
  }
}

function isoToUnixMs(value: string | undefined): number {
  const parsed = value ? Date.parse(value) : NaN
  return Number.isFinite(parsed) ? parsed : 0
}
