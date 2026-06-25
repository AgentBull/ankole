import * as kernel from '../../kernel'

export type JsonObject = Record<string, unknown>

/**
 * JSON-shaped host representation of an Actor Bus protobuf envelope.
 *
 * The native kernel owns protobuf validation. TypeScript keeps a JSON shape so
 * the worker code can stay close to the control-plane envelope contract.
 */
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

/**
 * Durable turn fence echoed by every worker reply.
 *
 * The control plane compares these fields with database rows before committing
 * a proposal, which makes late replies from old workers harmless.
 */
export type ActorTurnRef = {
  actor: {
    agent_uid: string
    display_name?: string
    role?: string
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
 * complete computer runtime owns the local AI loop and function calling.
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

export type TurnModelRef = {
  profile: string
  provider_id: string
  model: string
}

export type LlmProviderCredentialRequest = {
  request_id: string
  agent_uid: string
  session_id: string
  profile: string
  purpose: 'ai_turn' | 'codex_subagent' | 'live_check'
}

export type LlmProviderCredentialResponse = {
  request_id: string
  agent_uid: string
  session_id: string
  profile: string
  provider_id: string
  provider_source: string
  model: string
  base_url?: string
  connection_options_json?: JsonObject
  provider_options_json?: JsonObject
  credential: string
  credential_mode: string
  source_metadata_json?: JsonObject
}

export type LlmProviderCredentialRejected = {
  request_id: string
  agent_uid: string
  session_id: string
  profile: string
  code: string
  message?: string
}

/**
 * Encodes an envelope through the kernel Actor Bus codec.
 */
export function encodeEnvelope(envelope: ActorBusEnvelope): Buffer {
  return kernel.actorBusEncodeEnvelope(envelope)
}

/**
 * Decodes protobuf bytes into the JSON host representation used by this worker.
 */
export function decodeEnvelope(bytes: Buffer): ActorBusEnvelope {
  return kernel.actorBusDecodeEnvelope(bytes) as ActorBusEnvelope
}

/**
 * Extracts a turn-start payload and fails fast on wrong envelope types.
 */
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
