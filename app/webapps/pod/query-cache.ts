import { mergeMessageWindow } from './state/message-history'
import type { QueryClient, QueryKey } from '@tanstack/react-query'
import { podKeys } from './api'
import type { ConversationDetail } from './api'

/** A POST acknowledgement cannot replace history already read after its commit. */
export async function acceptConversationResult(client: QueryClient, result: ConversationDetail): Promise<void> {
  const queryKey = podKeys.detail(result.conversation.id)
  await client.cancelQueries({ queryKey, exact: true }, { revert: false })
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

async function refreshQuery(client: QueryClient, queryKey: QueryKey, exact = true): Promise<void> {
  const filter = { queryKey, exact }
  // Invalidation alone can reuse a pending first GET with no cached data.
  await client.cancelQueries(filter)
  await client.invalidateQueries(filter)
}
