import { isRecord, type JsonObject, type RuntimeFabricEnvelope } from './runtime_fabric'

export type { JsonObject } from './runtime_fabric'

/**
 * Durable turn fence echoed by every worker reply.
 *
 * The control plane compares these fields with database rows before accepting
 * durable output, which makes late replies from old workers harmless.
 */
export type ActorTurnRef = {
  actor: {
    agent_uid: string
    session_id: string
  }
  activation_uid: string
  actor_epoch: number
  actor_event_id: string
  revision: number
}

/**
 * Actor event payload delivered to the computer worker.
 *
 * One worker execution handles exactly one actor_event_id.
 */
export type ActorEventEnvelope = {
  actor_event_id: string
  queue_sequence: number
  type: string
  source_event_id: string
  binding_name?: string
  signal_channel_id?: string
  provider_thread_id?: string
  source_entry_id?: string
  payload_json?: JsonObject
}

export type TurnStart = {
  turn: ActorTurnRef
  actor_event: ActorEventEnvelope
  model_ref?: TurnModelRef | null
  request_context?: JsonObject
}

export type TurnSteerUpdate = {
  turn: ActorTurnRef
  actorEvent?: ActorEventEnvelope
}

export type MailboxUpdated = {
  turn?: ActorTurnRef
  actor_event: ActorEventEnvelope
  reason?: string
}

export type TurnControl = {
  turn?: ActorTurnRef
  command?: string
  payload_json?: JsonObject
}

export type TurnModelRef = {
  profile: string
  provider_id: string
  model: string
  provider_kind?: string
  input_modalities?: string[]
  vision_fallback_model_ref?: TurnModelRef | null
}

/**
 * Extracts a turn-start payload and fails fast on wrong envelope types.
 */
export function turnStartFromEnvelope(envelope: RuntimeFabricEnvelope): TurnStart {
  if (envelope.body.type !== 'turn_start') {
    throw new Error(`expected turn_start envelope, got ${envelope.body.type}`)
  }

  const turnStart = envelope.body.turn_start
  if (!isRecord(turnStart)) {
    throw new Error('turn_start body is missing')
  }

  const raw = turnStart as Partial<TurnStart>
  const actorEvent = raw.actor_event
  if (!isRecord(actorEvent)) {
    throw new Error('turn_start.actor_event is required')
  }
  const turn = turnRefFromRaw(raw.turn, 'turn_start.turn')

  return {
    ...raw,
    turn,
    actor_event: actorEvent as ActorEventEnvelope
  } as TurnStart
}

export function mailboxUpdatedFromEnvelope(envelope: RuntimeFabricEnvelope): MailboxUpdated {
  if (envelope.body.type !== 'mailbox_updated') {
    throw new Error(`expected mailbox_updated envelope, got ${envelope.body.type}`)
  }

  const mailboxUpdated = envelope.body.mailbox_updated
  if (!isRecord(mailboxUpdated)) {
    throw new Error('mailbox_updated body is missing')
  }

  const raw = mailboxUpdated as Partial<MailboxUpdated>
  const actorEvent = raw.actor_event
  if (!isRecord(actorEvent)) {
    throw new Error('mailbox_updated.actor_event is required')
  }

  return {
    ...raw,
    actor_event: actorEvent as ActorEventEnvelope
  } as MailboxUpdated
}

export function turnControlFromEnvelope(envelope: RuntimeFabricEnvelope): TurnControl {
  if (envelope.body.type !== 'turn_control') {
    throw new Error(`expected turn_control envelope, got ${envelope.body.type}`)
  }

  const turnControl = envelope.body.turn_control
  if (!isRecord(turnControl)) {
    throw new Error('turn_control body is missing')
  }

  return turnControl as TurnControl
}

function turnRefFromRaw(value: unknown, path: string): ActorTurnRef {
  if (!isRecord(value)) {
    throw new Error(`${path} is required`)
  }

  const actor = value.actor
  if (!isRecord(actor)) {
    throw new Error(`${path}.actor is required`)
  }

  return {
    actor: {
      agent_uid: requiredString(actor.agent_uid, `${path}.actor.agent_uid`),
      session_id: requiredString(actor.session_id, `${path}.actor.session_id`)
    },
    activation_uid: requiredString(value.activation_uid, `${path}.activation_uid`),
    actor_epoch: requiredNumber(value.actor_epoch, `${path}.actor_epoch`),
    actor_event_id: requiredString(value.actor_event_id, `${path}.actor_event_id`),
    revision: requiredNumber(value.revision, `${path}.revision`)
  }
}

function requiredString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${path} is required`)
  }
  return value
}

function requiredNumber(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${path} is required`)
  }
  return value
}
