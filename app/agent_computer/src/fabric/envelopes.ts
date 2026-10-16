import { create } from '@bufbuild/protobuf'
import { createEnvelope, ControlShutdownSchema, envelopeHeader, type Envelope } from './envelope_proto'

/**
 * Reports that this worker has stopped accepting new turns and is draining its
 * existing tasks. The control plane keeps the route live for terminal writes.
 */
export function controlShutdownEnvelope(reason: string): Envelope {
  const messageID = `control-shutdown-${crypto.randomUUID()}`

  return createEnvelope({
    ...envelopeHeader(messageID),
    body: {
      case: 'controlShutdown',
      value: create(ControlShutdownSchema, { reason })
    }
  })
}
