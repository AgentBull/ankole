import { InternalAPIError, internalAPIGet, internalAPIPost } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'

export type WorkplaceAgent = { uid: string; displayName: string }
export type Conversation = {
  id: string
  title: string
  agent: WorkplaceAgent & { active: boolean }
  lastActivityAt: string
}
export type ConversationMessage = {
  id: string
  seq: number
  authorType: 'human' | 'agent' | 'system'
  authorUID: string | null
  kind: 'message' | 'notice'
  text: string
  createdAt: string
  replyToMessageID: string | null
  signalID: string | null
}
export type ConversationStatus = {
  state: 'idle' | 'queued' | 'running' | 'retrying'
  retryAt: string | null
}
export type ConversationDetail = {
  conversation: Conversation
  messages: ConversationMessage[]
  status: ConversationStatus
}
export type MessageSubmission = {
  conversationID: string
  messageID: string
  agentUID: string
  text: string
}

const base = '/.internal-apis/workplace'
export const workplaceKeys = {
  agents: ['workplace', 'agents'] as const,
  conversations: ['workplace', 'conversations'] as const,
  detail: (id: string) => ['workplace', 'conversation', id] as const
}
export const agentsQuery = {
  queryKey: workplaceKeys.agents,
  queryFn: () => internalAPIGet<{ agents: WorkplaceAgent[] }>(`${base}/agents`)
}
export const conversationsQuery = {
  queryKey: workplaceKeys.conversations,
  queryFn: () => internalAPIGet<{ conversations: Conversation[] }>(`${base}/conversations`)
}
export function conversationQuery(id: string) {
  return {
    queryKey: workplaceKeys.detail(id),
    queryFn: () => internalAPIGet<ConversationDetail>(`${base}/conversations/${encodeURIComponent(id)}`),
    retry: (failureCount: number, error: unknown) => !conversationNotFound(error) && failureCount < 1
  }
}
export function postMessage(submission: MessageSubmission, create: boolean): Promise<ConversationDetail> {
  const { conversationID, messageID, agentUID, text } = submission
  return create
    ? internalAPIPost(`${base}/conversations`, { conversationID, messageID, agentUID, text })
    : internalAPIPost(`${base}/conversations/${encodeURIComponent(conversationID)}/messages`, { messageID, text })
}
export function conversationEventsURL(id: string): string {
  return `${base}/conversations/${encodeURIComponent(id)}/events`
}

export function conversationNotFound(error: unknown): boolean {
  return (
    error instanceof InternalAPIError &&
    error.status === 404 &&
    requestErrorCode(error.payload) === 'conversation_not_found'
  )
}
