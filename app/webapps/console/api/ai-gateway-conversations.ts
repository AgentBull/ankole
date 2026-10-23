import { fromDocument, nextPageAfter } from './json-api'
import {
  getAiGatewayConversationOptions,
  listAiGatewayConversationsOptions,
  listAiGatewayMessagesOptions
} from './v2/generated/@tanstack/react-query.gen'
import type {
  GetAiGatewayConversationResponse,
  ListAiGatewayConversationsResponse,
  ListAiGatewayMessagesResponse
} from './v2/generated/types.gen'

function conversationsPage(document: ListAiGatewayConversationsResponse) {
  return { conversations: fromDocument(document), nextAfter: nextPageAfter(document) }
}

// A message holds a list of Responses API items, each a JSON object.
function messagesPage(document: ListAiGatewayMessagesResponse) {
  return {
    messages: fromDocument(document).map(message => ({
      ...message,
      content: message.content as Record<string, unknown>[]
    })),
    nextAfter: nextPageAfter(document)
  }
}

function conversationFromDocument(document: GetAiGatewayConversationResponse) {
  return fromDocument(document)
}

export type AIGatewayConversationItem = ReturnType<typeof conversationFromDocument>
export type AIGatewayMessageItem = ReturnType<typeof messagesPage>['messages'][number]

/** The query of one page of conversations, with `{ conversations, nextAfter }` as its data. */
export function aiGatewayConversationsOptions(query: {
  search?: string
  subject_uid?: string
  active?: boolean
  min_messages?: number
  after?: string
  limit: number
}) {
  const { after, limit, ...filters } = query
  return {
    ...listAiGatewayConversationsOptions({ query: { ...filters, page: { limit, after } } }),
    select: conversationsPage
  }
}

/** The query of one conversation, with the flat record as its data. */
export function aiGatewayConversationOptions(id: string) {
  return { ...getAiGatewayConversationOptions({ path: { id } }), select: conversationFromDocument }
}

/** The query of one page of the messages of a conversation, oldest first. */
export function aiGatewayMessagesOptions(conversationID: string, page: { after?: string; limit: number }) {
  return {
    ...listAiGatewayMessagesOptions({ path: { conversation_id: conversationID }, query: { page } }),
    select: messagesPage
  }
}
