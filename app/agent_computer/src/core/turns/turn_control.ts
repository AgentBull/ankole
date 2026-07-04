import type { TurnStart, TurnSteerUpdate } from '../../actor_lane'
import type { AgentMessage } from '../types'
import { userMessage } from '../llm'
import { actorEventText } from './actor_event_text'

export function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.actor_event.type === 'im.message.may_intervene'
}

export function steeringMessages(turnStart: TurnStart, updates: TurnSteerUpdate[]): AgentMessage[] {
  const applicable = applicableSteeringUpdates(turnStart, updates)

  if (applicable.length === 0) return []

  const messages: AgentMessage[] = applicable.map(update => {
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

export function applicableSteeringUpdates(turnStart: TurnStart, updates: TurnSteerUpdate[]): TurnSteerUpdate[] {
  return updates.filter(update => {
    return (
      update.turn.actor.agent_uid === turnStart.turn.actor.agent_uid &&
      update.turn.actor.session_id === turnStart.turn.actor.session_id &&
      update.turn.activation_uid === turnStart.turn.activation_uid &&
      update.turn.actor_epoch === turnStart.turn.actor_epoch &&
      update.turn.actor_event_id === turnStart.turn.actor_event_id &&
      update.turn.revision > turnStart.turn.revision
    )
  })
}
