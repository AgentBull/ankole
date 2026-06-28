import type { AssistantModelMessage, ToolModelMessage } from '@/ai-gateway-client/provider-utils'

/**
 * A message that was generated during the generation process.
 * It can be either an assistant message or a tool message.
 */
export type ResponseMessage = AssistantModelMessage | ToolModelMessage
