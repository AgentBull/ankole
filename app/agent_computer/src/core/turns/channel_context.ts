import { arrayPath, firstString, isRecord, stringArg, type JsonObject as JSONObject } from '@pleisto/active-support'
import { type UserMessage, userMessage } from '../llm'
import { formatConversationTime } from './message_context'

const ACTOR_EVENT_REFERENCE_SUFFIX = /\s*[（(]actor-event::[0-9a-f-]+[）)]\s*$/iu

/**
 * Projects structured shared-channel rows into one quoted model input.
 *
 * Other agents' messages stay attributed inside the transcript instead of
 * becoming assistant-role history for the current agent. The current actor
 * event remains a separate user message immediately after this context block.
 * Channel standing orders, when the binding activates them, render as their
 * own tagged block so the room policy is visible on every turn.
 */
export function channelContextModelMessages(
  payload: JSONObject | undefined,
  opts: { timezone?: string | null } = {}
): UserMessage[] {
  const timezone = opts.timezone || 'UTC'
  const lines = arrayPath(payload, ['data', 'channel_context', 'messages'])
    .map(value => channelContextLine(value, timezone))
    .filter((line): line is string => line !== undefined)

  const blocks: string[] = []
  const standingOrders = channelStandingOrders(payload)
  if (standingOrders) {
    blocks.push(
      [
        'Standing orders of this channel (member-set policy for your behavior here):',
        '<channel_standing_orders>',
        standingOrders,
        '</channel_standing_orders>'
      ].join('\n')
    )
  }

  if (lines.length > 0) {
    blocks.push(
      [
        'Quoted recent conversation from the same channel, before the current message:',
        '<channel_context>',
        ...lines,
        '</channel_context>'
      ].join('\n')
    )
  }

  if (blocks.length === 0) return []

  return [userMessage(blocks.join('\n\n'))]
}

function channelStandingOrders(payload: JSONObject | undefined): string | undefined {
  if (!isRecord(payload)) return undefined
  const data = payload.data
  if (!isRecord(data)) return undefined
  const channel = data.channel
  if (!isRecord(channel)) return undefined

  const orders = firstString(channel, ['standing_orders'])?.trim()
  return orders ? orders : undefined
}

function channelContextLine(value: unknown, timezone: string): string | undefined {
  if (!isRecord(value)) return undefined

  const role = stringArg(value, 'role') === 'agent' ? 'agent' : 'human'
  const rawText = firstString(value, ['text'])
  const text = rawText && role === 'agent' ? rawText.replace(ACTOR_EVENT_REFERENCE_SUFFIX, '').trimEnd() : rawText
  if (!text) return undefined

  const speaker = firstString(value, ['speaker']) ?? 'Unknown'
  const sentAt = firstString(value, ['sent_at'])
  const formattedSentAt = sentAt ? formatConversationTime(sentAt, timezone) : undefined
  const prefix = [formattedSentAt ? `[${formattedSentAt}]` : undefined, `[${role}]`, speaker]
    .filter((part): part is string => part !== undefined)
    .join(' ')

  return `${prefix}: ${text}`
}
