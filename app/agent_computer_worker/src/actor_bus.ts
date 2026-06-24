import * as kernel from '../../kernel'

export type JsonObject = Record<string, unknown>

export type ActorBusEnvelope = {
  protocol_version: 1
  message_id: string
  correlation_id?: string
  seq?: number
  lane: string
  sent_at_unix_ms?: number
  durability: string
  body: {
    type: string
    [key: string]: unknown
  }
}

export type ActorTurnRef = {
  actor: {
    agent_uid: string
    session_id: string
  }
  activation_uid: string
  actor_epoch: number
  llm_turn_id: string
  revision: number
}

export type ActorInputEnvelope = {
  actor_input_id: string
  broker_sequence: number
  type: string
  ingress_event_id: string
  provider_entry_id?: string
  payload_json?: JsonObject
}

export type TurnStart = {
  turn: ActorTurnRef
  inputs: ActorInputEnvelope[]
}

export function encodeEnvelope(envelope: ActorBusEnvelope): Buffer {
  return kernel.actorBusEncodeEnvelope(envelope)
}

export function decodeEnvelope(bytes: Buffer): ActorBusEnvelope {
  return kernel.actorBusDecodeEnvelope(bytes) as ActorBusEnvelope
}

export function turnStartFromEnvelope(envelope: ActorBusEnvelope): TurnStart {
  if (envelope.body.type !== 'turn_start') {
    throw new Error(`expected turn_start envelope, got ${envelope.body.type}`)
  }

  const turnStart = envelope.body.turn_start
  if (!isRecord(turnStart)) {
    throw new Error('turn_start body is missing')
  }

  return turnStart as TurnStart
}

export function isRecord(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
