import { authenticationRef, podID } from '../common/browser-context'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'

export type {
  PodAgent,
  PodActivity,
  PodActivityItem,
  ConversationMessage,
  ConversationStatus,
  ConversationDetail,
  ConversationCreateRequest as MessageSubmission
} from '../common/api/generated/types.gen'
import type {
  ConversationDetail,
  ConversationCreateRequest as MessageSubmission
} from '../common/api/generated/types.gen'
import {
  podAgents,
  podConversations,
  conversationDetail,
  createConversation,
  postConversationMessage
} from '../common/api/generated/sdk.gen'

export const podKeys = {
  get agents() {
    return [...contextKey(), 'agents'] as const
  },
  get conversations() {
    return [...contextKey(), 'conversations'] as const
  },
  detail: (id: string) => [...contextKey(), 'conversation', id] as const
}
export const agentsQuery = {
  queryKey: podKeys.agents,
  queryFn: () => podAgents()
}
export const conversationsQuery = {
  queryKey: podKeys.conversations,
  queryFn: () => podConversations()
}
export function conversationQuery(id: string) {
  return {
    queryKey: podKeys.detail(id),
    queryFn: () => conversationDetail({ path: { id } }),
    retry: (failureCount: number, error: unknown) => !conversationNotFound(error) && failureCount < 1
  }
}
export function postMessage(submission: MessageSubmission, create: boolean): Promise<ConversationDetail> {
  const { conversationID, messageID, agentUID, text } = submission
  return create
    ? createConversation({ body: { conversationID, messageID, agentUID, text } })
    : postConversationMessage({ path: { id: conversationID }, body: { messageID, text } })
}
export function conversationEventsURL(id: string): string {
  const query = new URLSearchParams()
  const authentication = authenticationRef()
  const tenant = podID()
  if (authentication) query.set('authentication_ref', authentication)
  if (tenant) query.set('tenant_id', tenant)
  const suffix = query.size ? `?${query}` : ''
  return `/.internal-apis/pod/conversations/${encodeURIComponent(id)}/events${suffix}`
}

export function conversationNotFound(error: unknown): boolean {
  return (
    error instanceof InternalAPIError &&
    error.status === 404 &&
    requestErrorCode(error.payload) === 'conversation_not_found'
  )
}

function contextKey() {
  return ['pod', authenticationRef() ?? 'anonymous', podID() ?? 'unselected'] as const
}
