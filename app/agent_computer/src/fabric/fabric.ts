import * as kernel from '../../../kernel'

export type { JsonObject } from '@pleisto/active-support'

/**
 * JSON-shaped host representation of a RuntimeFabric protobuf envelope.
 *
 * The native kernel owns protobuf validation. TypeScript keeps a JSON shape so
 * the worker code can stay close to the control-plane envelope contract.
 */
export type RuntimeFabricEnvelope = {
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
 * Encodes an envelope through the kernel RuntimeFabric codec.
 */
export function encodeEnvelope(envelope: RuntimeFabricEnvelope): Buffer {
  return kernel.runtimeFabricEncodeEnvelope(envelope)
}

/**
 * Decodes protobuf bytes into the JSON host representation used by this worker.
 */
export function decodeEnvelope(bytes: Buffer): RuntimeFabricEnvelope {
  return kernel.runtimeFabricDecodeEnvelope(bytes) as RuntimeFabricEnvelope
}
