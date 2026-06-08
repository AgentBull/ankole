// External Gateway stable runtime surface.

export { adapterSupportsCapability, requireOutboundCapability } from './capabilities'
export type {
  ExternalGatewayActionEvent,
  ExternalGatewayAdapter,
  ExternalGatewayAdapterCapabilities,
  ExternalGatewayAdapterContext,
  ExternalGatewayBeginStreamingCardInput,
  ExternalGatewayInboundCapability,
  ExternalGatewayMessageDeletedEvent,
  ExternalGatewayMessageInput,
  ExternalGatewayMessageReconciliation,
  ExternalGatewayOutboundCapability,
  ExternalGatewayOutboundOptions,
  ExternalGatewayRawMessage,
  ExternalGatewayReactionEvent,
  ExternalGatewayRoomInput,
  ExternalGatewayStreamingCardHandle,
  ExternalGatewayStreamingCardStatus,
  ExternalGatewayWebhookOptions
} from './events'
export { parseMarkdown } from './markdown'
export { normalizeBullXStream } from './stream'
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
export type {
  AdapterPostableMessage,
  Attachment,
  Author,
  FileUpload,
  FormattedContent,
  LinkPreview,
  MarkdownTextChunk,
  PlanUpdateChunk,
  PostableAst,
  PostableMarkdown,
  PostableMessage,
  PostableRaw,
  RawMessage,
  StreamChunk,
  StreamOptions,
  TaskUpdateChunk
} from './types'
export { UnsupportedChannelCapabilityError } from './errors'
