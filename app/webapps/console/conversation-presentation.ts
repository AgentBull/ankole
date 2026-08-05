import { recordValue } from '@agentbull/active-support'
import type { AiGatewayConversationItem as AIGatewayConversationItem } from './api/generated/types.gen'
import i18n from '../common/i18n'

type ConversationNameSource = Pick<AIGatewayConversationItem, 'conversation_key' | 'display_name' | 'kind' | 'metadata'>

/** Returns the operator-facing name without exposing an internal session key as a title. */
export function conversationDisplayName(conversation: ConversationNameSource): string {
  const explicitName = conversation.display_name?.trim()
  if (explicitName) return explicitName

  if (conversation.kind === 'dreaming') {
    const brain = recordValue(conversation.metadata.brain)
    if (brain?.visibility === 'shared') return i18n.t('console.brain.store_shared')
    if (brain?.visibility === 'self') return i18n.t('console.brain.store_self')
  }

  if (conversation.kind === 'dreaming' || conversation.kind === 'job' || conversation.kind === 'responses_api') {
    return i18n.t(`console.conversations.kind.${conversation.kind}`)
  }

  return conversation.conversation_key
}
