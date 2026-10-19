import { authenticationRef, podID } from '../common/browser-context'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { mergeMessageWindow } from './state/message-history'
import { replaceEqualDeep, type QueryClient } from '@tanstack/react-query'

export type {
  PodAgent,
  PodActivity,
  PodActivityItem,
  ConversationMessage,
  ConversationStatus,
  ConversationDetail,
  ConversationPendingInput,
  ConversationQueueRequest
} from '../common/api/generated/types.gen'
import type {
  ConversationDetail,
  ConversationQueueRequest,
  ConversationCreateRequest,
  ConversationAttachmentReceipt
} from '../common/api/generated/types.gen'
import {
  podAgents,
  podConversations,
  conversationDetail,
  createConversation,
  postConversationMessage,
  updateConversationQueue,
  uploadConversationAttachment
} from '../common/api/generated/sdk.gen'

/** Local attachment IDs identify the captured draft; the API receives only signed receipts. */
export type MessageSubmission = ConversationCreateRequest & { attachmentIDs?: string[] }

export function uploadAttachment(
  file: File,
  fileID: string,
  signal: AbortSignal
): Promise<ConversationAttachmentReceipt> {
  return uploadConversationAttachment({ body: { file, fileID }, signal })
}

export const podKeys = {
  get agents() {
    return [...contextKey(), 'agents'] as const
  },
  get conversations() {
    return [...contextKey(), 'conversations'] as const
  },
  pageConversations: (pageID: string) => [...podKeys.conversations, 'page', pageID] as const,
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
  const { conversationID, messageID, agentUID, text, pageID, deliveryMode, attachments, modelProfile } = submission
  const content = { text, deliveryMode, ...(attachments?.length ? { attachments } : {}) }
  return create
    ? createConversation({
        body: { conversationID, messageID, agentUID, modelProfile, ...content, ...(pageID ? { pageID } : {}) }
      })
    : postConversationMessage({ path: { id: conversationID }, body: { messageID, ...content } })
}

export function updateQueue(conversationID: string, body: ConversationQueueRequest): Promise<ConversationDetail> {
  return updateConversationQueue({ path: { id: conversationID }, body })
}
export function conversationEventsURL(id: string): string {
  const query = new URLSearchParams()
  const authentication = authenticationRef()
  if (authentication) query.set('authentication_ref', authentication)
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
