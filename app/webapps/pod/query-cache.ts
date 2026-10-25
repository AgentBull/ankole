import { mergeMessageWindow } from './state/message-history'
import { isCancelledError, type QueryClient, type QueryKey } from '@tanstack/react-query'
import { podKeys } from './api'
import type { ConversationDetail } from './api'

/** A POST acknowledgement cannot replace history already read after its commit. */
export async function acceptConversationResult(client: QueryClient, result: ConversationDetail): Promise<void> {
  const queryKey = podKeys.detail(result.conversation.id)
  await client.cancelQueries({ queryKey, exact: true })
  client.setQueryData<ConversationDetail>(queryKey, current =>
    current && current.messageRange.lastSeq > result.messageRange.lastSeq
      ? mergeMessageWindow(current, { ...current, removedMessageIDs: result.removedMessageIDs })
      : mergeMessageWindow(current, result)
  )
}

/** Every event must read a snapshot taken after the event was received. */
export async function refreshConversationQueries(client: QueryClient, conversationID: string): Promise<void> {
  await Promise.all([
    refreshQuery(client, podKeys.detail(conversationID)),
    refreshQuery(client, podKeys.conversations, false)
  ])
}

/** A user recovery follows the current read when a later room event replaces it. */
export async function refreshConversationDetail(client: QueryClient, conversationID: string) {
  await refreshConversationQueries(client, conversationID)
  const cache = client.getQueryCache()
  const filter = { queryKey: podKeys.detail(conversationID), exact: true }
  let query = cache.find<ConversationDetail>(filter)
  while (query?.state.fetchStatus === 'fetching') {
    try {
      await query.promise
    } catch (error) {
      if (!isCancelledError(error)) throw error
    }
    query = cache.find<ConversationDetail>(filter)
  }
  if (query?.state.status === 'error') throw query.state.error
  return query?.state.data
}

async function refreshQuery(client: QueryClient, queryKey: QueryKey, exact = true): Promise<void> {
  const filter = { queryKey, exact }
  // Invalidation alone can reuse a pending first GET with no cached data.
  await client.cancelQueries(filter)
  await client.invalidateQueries(filter)
}
