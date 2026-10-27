import i18n from '../common/i18n'
import { authenticationRef, podID } from '../common/browser-context'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { mergeMessageWindow } from './state/message-history'
import { replaceEqualDeep, type QueryClient } from '@tanstack/react-query'

import type {
  ConversationDetailResponse,
  CreateConversationData,
  UpdateConversationQueueData,
  PodAgentsResponse
} from './api/generated/types.gen'
export { uploadAttachment } from './native-transfers'
import {
  podAgents,
  podConversations,
  conversationDetail,
  createConversation,
  postConversationMessage,
  updateConversationQueue
} from './api/generated/sdk.gen'

export type ConversationDetail = ConversationDetailResponse
export type ConversationMessage = ConversationDetail['messages'][number]
export type ConversationPendingInput = ConversationDetail['pendingQueues'][number]['inputs'][number]
export type ConversationAttachment = ConversationMessage['attachments'][number]
export type ConversationCreateRequest = CreateConversationData['body']['data']
export type ConversationQueueRequest = UpdateConversationQueueData['body']['data']
export type PodAgent = PodAgentsResponse['agents'][number]
export type PodActivity = ConversationDetail['activities'][number]
export type PodActivityItem = PodActivity['tools'][number]

/** Local attachment IDs identify the captured draft; the API receives only signed receipts. */
export type MessageSubmission = Omit<
  ConversationCreateRequest,
  'mentions' | 'links' | 'agentUIDs' | 'participantUIDs'
> & {
  attachmentIDs?: string[]
  targetAgentUID?: string
  mentions?: { type: 'agent' | 'human'; uid: string; displayName?: string }[]
  links?: { kind: 'page' | 'message'; id: string; quote?: string }[]
}

export const podKeys = {
  get agents() {
    return [...contextKey(), 'agents'] as const
  },
  get conversations() {
    return [...contextKey(), 'conversations'] as const
  },
  conversationSearch: (query = '') =>
    [...podKeys.conversations, ...(query.trim() ? ['search', query.trim()] : [])] as const,
  pageConversations: (pageID: string) => [...podKeys.conversations, 'page', pageID] as const,
  detail: (id: string) => [...contextKey(), 'conversation', id] as const
}
export const agentsQuery = {
  queryKey: podKeys.agents,
  queryFn: () => podAgents()
}
export const conversationSearchQuery = (query = '') => {
  const trimmed = query.trim()
  return {
    queryKey: podKeys.conversationSearch(trimmed),
    queryFn: ({ signal }: { signal: AbortSignal }) =>
      podConversations({ ...(trimmed ? { query: { query: trimmed } } : {}), signal })
  }
}
export const pageConversationsQuery = (pageID: string) => ({
  queryKey: podKeys.pageConversations(pageID),
  queryFn: () => podConversations({ query: { pageID } })
})
export function conversationQuery(id: string) {
  return {
    queryKey: podKeys.detail(id),
    queryFn: ({ client, signal }: { client: QueryClient; signal: AbortSignal }) =>
      conversationDetail({
        path: { id },
        signal,
        query: { loadedFirstSeq: client.getQueryData<ConversationDetail>(podKeys.detail(id))?.messageRange.firstSeq }
      }),
    structuralSharing: (current: unknown, incoming: unknown) =>
      replaceEqualDeep(
        current,
        mergeMessageWindow(current as ConversationDetail | undefined, incoming as ConversationDetail)
      ),
    retry: (failureCount: number, error: unknown) => !conversationNotFound(error) && failureCount < 1
  }
}
export function postMessage(submission: MessageSubmission, create: boolean): Promise<ConversationDetail> {
  const {
    conversationID,
    messageID,
    agentUID,
    text,
    pageID,
    deliveryMode,
    attachments,
    modelProfile,
    accessScope,
    mentions,
    links,
    targetAgentUID
  } = submission
  const content = {
    text,
    deliveryMode,
    mentions,
    links,
    targetAgentUID,
    ...(attachments?.length ? { attachments } : {})
  }
  return create
    ? createConversation({
        body: {
          data: {
            conversationID,
            messageID,
            agentUID,
            accessScope,
            modelProfile,
            ...content,
            ...(pageID ? { pageID } : {})
          }
        }
      })
    : postConversationMessage({ path: { id: conversationID }, body: { data: { messageID, ...content } } })
}

export function updateQueue(conversationID: string, body: ConversationQueueRequest): Promise<ConversationDetail> {
  return updateConversationQueue({ path: { id: conversationID }, body: { data: body } })
}
export function conversationEventsURL(id: string): string {
  const query = new URLSearchParams()
  const authentication = authenticationRef()
  if (authentication) query.set('authentication_ref', authentication)
  const suffix = query.size ? `?${query}` : ''
  return `/api/v2/pod/conversations/${encodeURIComponent(id)}/events${suffix}`
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

export function chatError(error: unknown): unknown {
  const payload = error instanceof InternalAPIError ? error.payload : error
  const raw = payload && typeof payload === 'object' && 'error' in payload ? payload.error : undefined
  const code = requestErrorCode(payload) ?? (typeof raw === 'string' ? raw : undefined)
  const key = code ? `pod.chat.errors.${code}` : ''
  return key && i18n.exists(key) ? new Error(i18n.t(key)) : error
}
