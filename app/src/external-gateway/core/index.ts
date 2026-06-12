// External Gateway stable runtime surface.

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
