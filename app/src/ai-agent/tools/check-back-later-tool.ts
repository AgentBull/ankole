import { z } from 'zod'
import { compact } from '@pleisto/active-support'
import type { AiAgentCheckbackSource, JsonValue } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { resolveCheckbackDueAt, CheckBackLaterAfterSchema } from '@/scheduler/schedule'
import { schedulerStore } from '@/scheduler/store'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import type { ClarifyRunBinding } from './clarify-tool'

// The schema is the model's contract. `after` (relative) and `at` (absolute)
// are mutually exclusive — the .refine enforces exactly one, so the model
// cannot send an ambiguous "in 1h, at 3pm". `check` and `context_summary` exist
// because the wakeup runs in a fresh turn with no live memory of now: the future
// agent only has what is captured here, so they steer that isolated check.
const CheckBackLaterParams = z
  .object({
    after: CheckBackLaterAfterSchema.optional().describe('Relative delay before checking back.'),
    at: z
      .string()
      .min(1)
      .optional()
      .describe('Absolute time to check back. If no offset is present, it is interpreted in system.timezone.'),
    reason: z.string().min(1).describe('Why it is not useful to decide right now.'),
    check: z.string().min(1).describe('What should be inspected or decided when the agent wakes up.'),
    context_summary: z.string().min(1).optional().describe('Concise context needed for the isolated future check.')
  })
  .strict()
  // XOR via boolean inequality: true when exactly one of the two is present.
  .refine(value => Boolean(value.after) !== Boolean(value.at), {
    message: 'Provide exactly one of after or at'
  })

export interface CheckBackLaterDetails {
  checkback_id: string
  due_at: string
  timezone: string
}

/**
 * Builds the `check_back_later` tool: lets the agent schedule a single future
 * self-wakeup when a decision is better made once time has passed (a deadline
 * approaches, a build finishes, "ask again tomorrow"). It is deliberately scoped
 * to a one-shot judgment call — recurring monitoring, cron, and dumb reminders
 * are out of scope, which the description states so the model does not reach for
 * it as a generic scheduler.
 *
 * The `binding` is what makes the future wake land back in the right place: the
 * scheduled row records the conversation, room/thread, and trigger so the wakeup
 * resumes the same agent in the same channel.
 */
export function createCheckBackLaterTool(
  binding: ClarifyRunBinding
): AgentTool<typeof CheckBackLaterParams, CheckBackLaterDetails> {
  return buildTool({
    name: 'check_back_later',
    label: 'Check back later',
    description:
      'Schedule a one-shot delayed self-wakeup when the current decision should be made after time has passed. Use for a specific future check, not for heartbeat, cron, recurring monitoring, or reminders that need no agent judgment. Do not infer or repeat old tasks from prior chats.',
    schema: CheckBackLaterParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(toolCallId, params): Promise<AgentToolResult<CheckBackLaterDetails>> {
      // Relative `after` and absolute `at` both resolve against the system
      // timezone so a bare wall-clock time means the operator's local time.
      const timezone = await loadSystemTimezone()
      const dueAt = resolveCheckbackDueAt({ after: params.after, at: params.at, timezone })
      const wakeMessage = checkbackWakeMessage({
        check: params.check,
        contextSummary: params.context_summary,
        dueAt,
        reason: params.reason,
        timezone
      })
      const row = await schedulerStore.createCheckback({
        agentUid: binding.agentUid,
        check: params.check,
        contextSummary: params.context_summary ?? null,
        dueAt,
        reason: params.reason,
        // Provenance the scheduler replays to re-target the wake: which room,
        // thread, and trigger message the original turn belonged to, plus the
        // tool_call_id for traceability.
        source: {
          binding_name: binding.bindingName,
          conversation_id: binding.conversationId,
          lease_id: binding.leaseId,
          provider_realm_id: binding.providerRealmId ?? null,
          provider_room_id: binding.providerRoomId || null,
          provider_thread_id: binding.providerThreadId || null,
          trigger_message_id: binding.triggerMessageId,
          tool_call_id: toolCallId
        } satisfies AiAgentCheckbackSource,
        timezone,
        wakeMessage
      })
      const details = {
        checkback_id: row.id,
        due_at: row.dueAt.toISOString(),
        timezone
      }
      return {
        content: [{ type: 'text', text: JSON.stringify({ ...details, status: 'scheduled' }) }],
        details
      }
    }
  })
}

/**
 * Builds the message the future agent wakes up to. It is written as an
 * instruction block, not a user message, and works hard to prevent two
 * misreads: treating the wake as a recurring heartbeat, and replaying stale
 * tasks from old chat history. It also tells the agent to stay silent unless the
 * user genuinely needs interrupting — a self-wake should not spam the channel.
 */
function checkbackWakeMessage(input: {
  check: string
  contextSummary?: string
  dueAt: Date
  reason: string
  timezone: string
}): JsonValue[] {
  return [
    {
      type: 'text',
      text: compact([
        '[check_back_later wakeup]',
        'This is a one-shot delayed wakeup, not a recurring heartbeat.',
        'The check below is the current task. Use the context as background only.',
        'Do not infer or repeat old tasks from prior chats.',
        "If nothing needs the user's attention, do not send a visible message.",
        'Send a visible message only when the user should be interrupted: meaningful result, blocker, needed decision, or time-sensitive risk.',
        `Due at: ${input.dueAt.toISOString()} (${input.timezone})`,
        `Reason: ${input.reason}`,
        `Check: ${input.check}`,
        input.contextSummary ? `Context: ${input.contextSummary}` : ''
      ]).join('\n')
    }
  ]
}
