// @ts-nocheck
import type { AssistantModelMessage, ToolModelMessage } from '@/llm/provider-utils'

/**
 * A message that was generated during the generation process.
 * It can be either an assistant message or a tool message.
 */
export type ResponseMessage = AssistantModelMessage | ToolModelMessage
