// External Gateway stable runtime surface.
//
// The single entry point host code imports from. Everything re-exported here is
// considered stable for the rest of the app; the individual `core/*` modules
// are implementation detail and should not be imported directly from outside
// the gateway. Keeping the surface in one barrel makes the boundary explicit.

export { adapterSupportsCapability, requireOutboundCapability } from './capabilities'
export type {
  ExternalGatewayActionEvent,
  ExternalGatewayAdapter,
  ExternalGatewayAdapterCapabilities,
  ExternalGatewayAdapterContext,
  ExternalGatewayBeginStreamingCardInput,
  ExternalGatewayMessageDeletedEvent,
  ExternalGatewayMessageInput,
  ExternalGatewayMessageReconciliation,
  ExternalGatewayOutboundOptions,
  ExternalGatewayRawMessage,
  ExternalGatewayReactionEvent,
  ExternalGatewayReasoningTraceViewAuthInput,
  ExternalGatewayRoomInput,
  ExternalGatewayStreamingCardHandle,
  ExternalGatewayWebhookOptions
} from './events'
export {
  externalGatewayProjectionSink,
  DrizzleExternalGatewayProjectionSink,
  type ExternalGatewayMessage,
  type ExternalGatewayProjectDeleteInput,
  type ExternalGatewayProjectionSink,
  type ExternalGatewayProjectMessageInput
} from './projection'
export {
  BunRedisExternalGatewayVisibleOutputStream,
  externalGatewayVisibleOutputStream,
  type ExternalGatewayVisibleOutputEvent,
  type ExternalGatewayVisibleOutputEventType,
  type ExternalGatewayVisibleOutputRecord,
  type ExternalGatewayVisibleOutputStream,
  type ExternalGatewayVisibleOutputStreamKey,
  type ReadExternalGatewayVisibleOutputInput
} from './visible-output-stream'
export { UnsupportedChannelCapabilityError } from './errors'
