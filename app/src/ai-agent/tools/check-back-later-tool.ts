import { z } from 'zod'
import type { AiAgentCheckbackSource, JsonValue } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { resolveCheckbackDueAt, CheckBackLaterAfterSchema } from '@/scheduler/schedule'
import { schedulerStore } from '@/scheduler/store'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import type { ClarifyRunBinding } from './clarify-tool'

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
  .refine(value => Boolean(value.after) !== Boolean(value.at), {
    message: 'Provide exactly one of after or at'
  })

export interface CheckBackLaterDetails {
  checkback_id: string
  due_at: string
  timezone: string
}

export function createCheckBackLaterTool(
  binding: ClarifyRunBinding
): AgentTool<typeof CheckBackLaterParams, CheckBackLaterDetails> {
  return buildTool({
    name: 'check_back_later',
    label: 'Check back later',
    description:
      'Schedule a one-shot delayed self-wakeup when the current decision should be made after time has passed. This is not a heartbeat, cron, or recurring task.',
    schema: CheckBackLaterParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(toolCallId, params): Promise<AgentToolResult<CheckBackLaterDetails>> {
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
      text: [
        '[check_back_later wakeup]',
        `Due at: ${input.dueAt.toISOString()} (${input.timezone})`,
        `Reason: ${input.reason}`,
        `Check: ${input.check}`,
        input.contextSummary ? `Context: ${input.contextSummary}` : ''
      ]
        .filter(Boolean)
        .join('\n')
    }
  ]
}
