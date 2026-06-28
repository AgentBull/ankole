import type { TurnStart, TurnSteerUpdate } from '../actor_lane'
import type { AgentMessage } from '../core'
import { inputText } from './actor_input_text'
import { userMessage } from './turn_messages'

export function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.inputs.length > 0 && turnStart.inputs.every(input => input.type === 'im.message.may_intervene')
}

export function isCompressionTurn(turnStart: TurnStart): boolean {
  return turnStart.inputs.length > 0 && turnStart.inputs.every(input => input.type === 'command.compress')
}

export function turnRefAfterSteeringDrain(turnStart: TurnStart, updates: TurnSteerUpdate[]): TurnStart['turn'] {
  for (const update of applicableSteeringUpdates(turnStart, updates)) {
    turnStart.turn.revision = update.turn.revision
  }
  return turnStart.turn
}

export function steeringMessages(turnStart: TurnStart, updates: TurnSteerUpdate[]): AgentMessage[] {
  const applicable = applicableSteeringUpdates(turnStart, updates)

  if (applicable.length === 0) return []

  const messages: AgentMessage[] = [
    userMessage(
      'Runtime note:\nThe user sent /steer while this turn was running. Do not continue the previous tool plan by inertia; continue from the latest steering instructions below.'
    )
  ]

  for (const update of applicable) {
    turnStart.turn.revision = update.turn.revision
    for (const input of update.inputs) {
      messages.push(userMessage(`Steering instruction:\n${inputText(input.payload_json, input.type)}`))
    }
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
      update.turn.llm_turn_id === turnStart.turn.llm_turn_id &&
      update.turn.revision > turnStart.turn.revision
    )
  })
}
