import { compactRecord, deepString } from '@agentbull/active-support'
import type { ActorEventEnvelope, TurnStart } from '../../lanes/actor_lane'

export type ReplyRoute = {
  binding_name?: string
  signal_channel_id?: string
  provider_thread_id?: string
  source_entry_id?: string
}

/**
 * Returns the current reply route only when it has enough provider routing
 * information for future work.
 */
export function currentReplyRoute(turnStart: TurnStart): ReplyRoute | undefined {
  const route = replyRouteFromActorEvent(turnStart.actor_event)
  return route.binding_name && route.signal_channel_id ? route : undefined
}

/**
 * Extracts provider reply routing from the ActorEvent and its payload.
 */
export function replyRouteFromActorEvent(input: ActorEventEnvelope): ReplyRoute {
  const payload = input.payload_json
  return compactRecord({
    binding_name:
      input.binding_name ??
      deepString(payload, ['data', 'reply_route', 'binding_name']) ??
      deepString(payload, ['data', 'session', 'binding_name']),
    signal_channel_id:
      input.signal_channel_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'signal_channel_id']) ??
      nonEmptyDeepString(payload, ['data', 'channel', 'id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'signal_channel_id']),
    provider_thread_id:
      input.provider_thread_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'provider_thread_id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'provider_thread_id']),
    source_entry_id:
      input.source_entry_id ??
      nonEmptyDeepString(payload, ['data', 'reply_route', 'source_entry_id']) ??
      nonEmptyDeepString(payload, ['data', 'entry', 'source_entry_id'])
  })
}

function nonEmptyDeepString(value: unknown, path: string[]): string | undefined {
  const text = deepString(value, path)?.trim()
  return text ? text : undefined
}
