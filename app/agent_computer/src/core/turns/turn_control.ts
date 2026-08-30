import type { TurnStart, TurnSteerUpdate } from '../../lanes/actor_lane'
import type { Message } from '../types'
import { userMessage } from '../llm'
import { actorEventText } from './actor_event_text'

/**
 * Converts applicable active steering updates into model-visible user messages.
 *
 * The worker only uses mailbox updates that match the current durable turn
 * fence and have a newer revision; unrelated session traffic is ignored.
 */
export function steeringMessages(turnStart: TurnStart, updates: TurnSteerUpdate[]): Message[] {
  const applicable = applicableSteeringUpdates(turnStart, updates)

  if (applicable.length === 0) return []

  const messages: Message[] = applicable.map(update => {
    const steerText = update.actorEvent
      ? actorEventText(update.actorEvent.payload_json, update.actorEvent.type)
      : undefined
    const content = steerText
      ? [
          'Runtime note:',
          'The user sent /steer while this turn was running. Do not continue the previous tool plan by inertia.',
          '',
          'Steering instruction:',
          steerText
        ].join('\n')
      : [
          'Runtime note:',
          'A mailbox update arrived while this turn was running, but it did not include a steering actor event.',
          'Re-check the current task state before continuing.'
        ].join('\n')

    return userMessage(content)
  })

  for (const update of applicable) {
    turnStart.turn.revision = update.turn.revision
  }

  return messages
}

/**
 * Acknowledges steering only after its messages enter the next model input.
 */
export async function steeringMessagesWithAcknowledgement(
  turnStart: TurnStart,
  updates: TurnSteerUpdate[],
  onSteeringApplied?: (update: TurnSteerUpdate) => Promise<void>
): Promise<Message[]> {
  const applicable = applicableSteeringUpdates(turnStart, updates)
  const messages = steeringMessages(turnStart, applicable)

  for (const update of applicable) {
    await onSteeringApplied?.(update)
  }

  return messages
}

/**
 * Filters steering updates to the active turn fence and newer revisions only.
 */
function applicableSteeringUpdates(turnStart: TurnStart, updates: TurnSteerUpdate[]): TurnSteerUpdate[] {
  return updates
    .filter(update => {
      return (
        update.turn.actor.agent_uid === turnStart.turn.actor.agent_uid &&
        update.turn.actor.session_id === turnStart.turn.actor.session_id &&
        update.turn.activation_uid === turnStart.turn.activation_uid &&
        update.turn.actor_epoch === turnStart.turn.actor_epoch &&
        update.turn.actor_event_id === turnStart.turn.actor_event_id &&
        update.turn.revision > turnStart.turn.revision
      )
    })
    .sort((left, right) => left.turn.revision - right.turn.revision)
}
