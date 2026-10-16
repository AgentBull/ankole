import type { QueryClient, QueryKey } from '@tanstack/react-query'
import { podKeys } from './api'

/** Every event must read a snapshot taken after the event was received. */
export async function refreshConversationQueries(client: QueryClient, conversationID: string): Promise<void> {
  await Promise.all([refreshQuery(client, podKeys.detail(conversationID)), refreshQuery(client, podKeys.conversations)])
}

async function refreshQuery(client: QueryClient, queryKey: QueryKey): Promise<void> {
  const filter = { queryKey, exact: true }
  // Invalidation alone can reuse a pending first GET with no cached data.
  await client.cancelQueries(filter)
  await client.invalidateQueries(filter)
}
