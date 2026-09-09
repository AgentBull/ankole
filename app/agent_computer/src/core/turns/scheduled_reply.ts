import { safeJsonParse } from '@agentbull/active-support'
import { z } from 'zod'
import { zodToJSONSchema } from '../llm/tool-schema'

const ScheduledReply = z
  .object({
    outcome: z.enum(['reply', 'silent_success']),
    reply: z.string().nullable()
  })
  .strict()

export function scheduledReplyFormat() {
  return {
    format: {
      type: 'json_schema',
      name: 'scheduled_turn_result',
      strict: true,
      schema: zodToJSONSchema(ScheduledReply)
    }
  } as const
}

export function parseScheduledReply(text: string, silentSuccessAllowed: boolean) {
  const value = safeJsonParse(text).match({ ok: value => value, err: () => undefined })
  const parsed = ScheduledReply.safeParse(value)
  if (!parsed.success) return undefined
  const result = parsed.data
  if (result.outcome === 'silent_success') {
    return silentSuccessAllowed && result.reply === null ? result : undefined
  }
  return typeof result.reply === 'string' && result.reply.trim() !== '' ? result : undefined
}

export function scheduledReplyReminder(silentSuccessAllowed: boolean): string {
  return [
    'End this scheduled turn with one JSON object that matches scheduled_turn_result. Free-form final text and text control markers are invalid, even if an older task instruction asks for them.',
    'For a visible result, return {"outcome":"reply","reply":"the user-visible message"}. A failed or blocked check, required human action, material change, or time-sensitive risk requires this outcome.',
    silentSuccessAllowed
      ? 'If no visible update is useful, return {"outcome":"silent_success","reply":null}.'
      : 'Silent success is not allowed for this turn. Return a concise visible result.',
    'Do not repeat completed tool actions.'
  ].join('\n')
}
