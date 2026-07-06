import { match } from '@pleisto/active-support'
import type { JsonObject } from '@pleisto/active-support'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { TurnStart } from '../../lanes/actor_lane'
import type { CodexRuntimeRequesters } from './manager'
import { codexDelegationManager, type CodexDelegationSnapshot } from './manager'

const CodexDelegateParams = z.object({
  action: z
    .enum(['run', 'start', 'status', 'steer', 'stop'])
    .describe(
      'Codex delegation action. Use run for a foreground delegation that starts Codex and waits for a terminal result. Use start/status only for background delegation management.'
    ),
  prompt: z.string().min(1).describe('Task prompt for run/start, or steer text for steer.').optional(),
  delegation_id: z.string().min(1).describe('Delegation id for status/steer/stop.').optional(),
  workdir: z.string().describe('Workspace-relative path or /workspace path for Codex to use.').optional(),
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
  'Create one managed Codex subagent for an independent task.',
  'Use codex_delegate when work benefits from isolated context or can proceed while you continue. Do not use it for simple single-step work -- just do that directly.',
  'In Ankole, the managed subagent runs through the configured local Codex runtime with its own Codex app-server thread, toolset, and workdir.',
  'Only the delegation snapshot returns to your context window; intermediate tool results stay inside the subagent task.',
  '',
  'TWO MODES (choose by action):',
  '1. Foreground: action=run starts Codex and waits for a terminal result.',
  '2. Background: action=start returns a delegation_id immediately; use status/steer/stop to manage that delegation.',
  '',
  'WHEN TO USE codex_delegate:',
  '- Reasoning-heavy subtasks that need structured analysis, debugging, code review, or research synthesis',
  '- Self-contained software deliverables that need an implementation and validation loop in their own workdir',
  '- Tasks that would flood your context with intermediate data',
  '- Independent workstreams that benefit from isolated context or can proceed while you continue',
  '',
  'WHEN NOT TO USE (use these instead):',
  '- Mechanical multi-step work with no reasoning or implementation loop needed -> use command, read_file, patch, or another available tool',
  '- Single tool call -> just call the tool directly',
  '- Tasks needing user interaction -> subagents may ask for input, but the parent must steer or decide how to proceed',
  '',
  'IMPORTANT:',
  '- Subagents have NO memory of your conversation. Pass all relevant info (file paths, error messages, constraints) via the prompt field.',
  '- If the user is writing in a non-English language, or asked for output in a specific language / tone / style, say so in prompt (e.g. "respond in Chinese", "return output in Japanese"). Otherwise subagents default to English and their summaries will contaminate your final reply with the wrong language.',
  '- Subagents complete the assigned task, use tools independently when needed, and report concise findings. A subagent may create artifacts and run its own validation inside the delegated task.',
  '- Treat the delegation snapshot as the subagent task report. If the report lacks enough evidence for a user-visible claim, ask the subagent for a follow-up or inspect the relevant handle with available tools.',
  '- The subagent model/auth/runtime is not selected per call here; it follows the configured local Codex runtime for this Agent Computer.',
  '- Results are returned as a single delegation snapshot for this one delegated task.',
  '',
  'Actions:',
  '- run: foreground mode. Start Codex and wait until it succeeds, fails, is stopped, or needs user input. After run returns a terminal status, do not call status or run again for the same subtask unless the user asked for a retry or you have a concrete new subtask.',
  '- start: background mode. Enqueue a Codex task and return a delegation_id immediately.',
  '- status: inspect a known background delegation created with start, or recover a known delegation after process/restart. This is not needed after a completed run call.',
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
  return match(params.action)
    .with('run', async () => {
      const prompt = requiredPrompt(params)
      const snapshot = await codexDelegationManager.submit({
        turnStart: opts.turnStart,
        workspaceRoot: opts.workspaceRoot,
        toolCallId,
        request: {
          prompt,
          workdir: params.workdir,
          outputSchema: params.output_schema
        },
        requesters: opts,
        signal
      })
      return codexDelegationManager.wait(snapshot.delegation_id, signal)
    })
    .with('start', () =>
      codexDelegationManager.submit({
        turnStart: opts.turnStart,
        workspaceRoot: opts.workspaceRoot,
        toolCallId,
        request: {
          prompt: requiredPrompt(params),
          workdir: params.workdir,
          outputSchema: params.output_schema
        },
        requesters: opts,
        signal
      })
    )
    .with('status', () => statusSnapshot(params.delegation_id, opts))
    .with('steer', () =>
      codexDelegationManager.steer(requiredDelegationId(params), requiredPrompt(params), params.answers)
    )
    .with('stop', () => codexDelegationManager.stop(requiredDelegationId(params)))
    .exhaustive()
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
  result?: JsonObject
  error?: JsonObject
  last_event_seq?: number
  result_ref?: JsonObject
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
