import { isRecord, type JsonObject, type RuntimeFabricEnvelope } from './runtime_fabric'

export type { JsonObject } from './runtime_fabric'
export type ActorLaneEnvelope = RuntimeFabricEnvelope

/**
 * Durable turn fence echoed by every worker reply.
 *
 * The control plane compares these fields with database rows before committing
 * a proposal, which makes late replies from old workers harmless.
 */
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

/**
 * Actor input payload delivered to the computer worker.
 *
 * The worker receives actor inputs, not pre-rendered LLM messages, because the
 * complete Agent Computer runtime owns the AI loop and function calling.
 */
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
  model_ref?: TurnModelRef | null
}

export type TurnSteerUpdate = {
  turn: ActorTurnRef
  inputs: ActorInputEnvelope[]
}

export type MailboxUpdated = {
  turn?: ActorTurnRef
  inputs?: ActorInputEnvelope[]
  reason?: string
}

export type TurnModelRef = {
  profile: string
  provider_id: string
  model: string
}

/**
 * Extracts a turn-start payload and fails fast on wrong envelope types.
 */
export function turnStartFromEnvelope(envelope: ActorLaneEnvelope): TurnStart {
  if (envelope.body.type !== 'turn_start') {
    throw new Error(`expected turn_start envelope, got ${envelope.body.type}`)
  }

  const turnStart = envelope.body.turn_start
  if (!isRecord(turnStart)) {
    throw new Error('turn_start body is missing')
  }

  return turnStart as TurnStart
}

export function mailboxUpdatedFromEnvelope(envelope: ActorLaneEnvelope): MailboxUpdated {
  if (envelope.body.type !== 'mailbox_updated') {
    throw new Error(`expected mailbox_updated envelope, got ${envelope.body.type}`)
  }

  const mailboxUpdated = envelope.body.mailbox_updated
  if (!isRecord(mailboxUpdated)) {
    throw new Error('mailbox_updated body is missing')
  }

  return mailboxUpdated as MailboxUpdated
}
