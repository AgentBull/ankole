import type {
  BullXExternalGatewayActionEvent,
  BullXExternalGatewayAdapter,
  BullXExternalGatewayAdapterCapabilities,
  BullXExternalGatewayAdapterContext,
  BullXExternalGatewayFetchMessagesResult,
  BullXExternalGatewayHistoryCapability,
  BullXExternalGatewayInboundCapability,
  BullXExternalGatewayLogger,
  BullXExternalGatewayMessageDeletedEvent,
  BullXExternalGatewayMessageInput,
  BullXExternalGatewayOutboundCapability,
  BullXExternalGatewayRawMessage,
  BullXExternalGatewayReactionEvent,
  BullXExternalGatewayRoomInput,
  BullXExternalGatewayWebhookOptions
} from '@agentbull/bullx-sdk/plugins'

/**
 * App-local names for the SDK External Gateway adapter contract.
 *
 * The SDK is the plugin-facing source of truth. Keep this file as aliases only:
 * adding a second structural contract here makes app and plugin behavior drift
 * silently, which is exactly the class of bug that broke logger/debug handling.
 */
export type ExternalGatewayActionEvent<TRawEvent = unknown> = BullXExternalGatewayActionEvent<TRawEvent>
export type ExternalGatewayAdapter<TRawMessage = unknown> = BullXExternalGatewayAdapter<TRawMessage>
export type ExternalGatewayAdapterCapabilities = BullXExternalGatewayAdapterCapabilities
export type ExternalGatewayAdapterContext = BullXExternalGatewayAdapterContext
export type ExternalGatewayAdapterLogger = BullXExternalGatewayLogger
export type ExternalGatewayFetchResult<TRawMessage = unknown> =
  BullXExternalGatewayFetchMessagesResult<TRawMessage>
export type ExternalGatewayHistoryCapability = BullXExternalGatewayHistoryCapability
export type ExternalGatewayInboundCapability = BullXExternalGatewayInboundCapability
export type ExternalGatewayMessageDeletedEvent<TRawEvent = unknown> =
  BullXExternalGatewayMessageDeletedEvent<TRawEvent>
export type ExternalGatewayMessageInput<TRawMessage = unknown> = BullXExternalGatewayMessageInput<TRawMessage>
export type ExternalGatewayOutboundCapability = BullXExternalGatewayOutboundCapability
export type ExternalGatewayRawMessage<TRawMessage = unknown> = BullXExternalGatewayRawMessage<TRawMessage>
export type ExternalGatewayReactionEvent<TRawEvent = unknown> = BullXExternalGatewayReactionEvent<TRawEvent>
export type ExternalGatewayRoomInput = BullXExternalGatewayRoomInput
export type ExternalGatewayWebhookOptions = BullXExternalGatewayWebhookOptions
