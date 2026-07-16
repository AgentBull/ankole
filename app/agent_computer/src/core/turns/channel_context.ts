import { arrayPath, firstString, isRecord, stringArg, type JsonObject as JSONObject } from '@pleisto/active-support'
import { type UserMessage, userMessage } from '../llm'

/**
 * Projects structured shared-channel rows into one quoted model input.
 *
 * Other agents' messages stay attributed inside the transcript instead of
 * becoming assistant-role history for the current agent. The current actor
 * event remains a separate user message immediately after this context block.
 */
export function channelContextModelMessages(payload: JSONObject | undefined): UserMessage[] {
  const lines = arrayPath(payload, ['data', 'channel_context', 'messages'])
    .map(channelContextLine)
    .filter((line): line is string => line !== undefined)

  if (lines.length === 0) return []

  return [
    userMessage(
      [
        'Quoted recent conversation from the same channel, before the current message:',
        '<channel_context>',
        ...lines,
        '</channel_context>'
      ].join('\n')
    )
  ]
}

function channelContextLine(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined

  const text = firstString(value, ['text'])
  if (!text) return undefined

  const role = stringArg(value, 'role') === 'agent' ? 'agent' : 'human'
  const speaker = firstString(value, ['speaker']) ?? 'Unknown'
  const sentAt = firstString(value, ['sent_at'])
  const prefix = [sentAt ? `[${sentAt}]` : undefined, `[${role}]`, speaker]
    .filter((part): part is string => part !== undefined)
    .join(' ')

  return `${prefix}: ${text}`
}
