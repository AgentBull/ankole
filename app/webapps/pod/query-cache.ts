import { isRecord } from '@agentbull/active-support'
import { mergeMessageWindow } from './state/message-history'
import { isCancelledError, type QueryClient, type QueryKey } from '@tanstack/react-query'
import { podKeys } from './api'
import { metaKeys } from './meta-api'
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

/**
 * Every room event must read a snapshot taken after the event was received. The room stream owns only the room's
 * own queries: every committed room change also reaches the Pod's `conversations_changed` event, which refreshes the
 * conversation lists over a coalescing window.
 */
export async function refreshRoomQueries(client: QueryClient, conversationID: string): Promise<void> {
  await Promise.all([
    refreshQuery(client, podKeys.detail(conversationID)),
    refreshQuery(client, [...podKeys.detail(conversationID), 'peer'], false),
    refreshQuery(client, [...podKeys.detail(conversationID), 'execution'], false)
  ])
}

/** A write the viewer makes rereads the room and the conversation lists, so the sidebar shows it at once. */
export async function refreshConversationQueries(client: QueryClient, conversationID: string): Promise<void> {
  await Promise.all([refreshRoomQueries(client, conversationID), refreshQuery(client, podKeys.conversations, false)])
}

type RoomSummary = ConversationDetail['conversation']

/**
 * A confirmed read moves the viewer's read position forward in every cached copy of the room, so the sidebar clears
 * the unread dot without rereading the room or the lists. Ankole never moves a read position back, so the cache keeps
 * the larger position when an older read arrives later.
 */
export function acceptReadPosition(client: QueryClient, result: ConversationDetail): void {
  const { id, viewer } = result.conversation
  const read = (row: RoomSummary): RoomSummary | undefined => {
    if (row.id !== id || row.viewer.lastReadSeq >= viewer.lastReadSeq) return undefined
    return {
      ...row,
      viewer: { ...row.viewer, lastReadSeq: viewer.lastReadSeq, lastVisitedAt: viewer.lastVisitedAt },
      // Unread compares the read position with the last notifiable message, which never passes the last message.
      rowStatus: row.rowStatus === 'unread' && viewer.lastReadSeq >= row.lastMessageSeq ? 'idle' : row.rowStatus
    }
  }
  client.setQueryData<ConversationDetail>(podKeys.detail(id), current => {
    const conversation = current && read(current.conversation)
    return conversation ? { ...current, conversation } : current
  })
  client.setQueriesData({ queryKey: podKeys.conversations }, (data: unknown) => readRooms(data, read))
}

/** Conversation lists cache rows as an array, a page of `conversations`, or infinite pages of them. */
function readRooms(data: unknown, read: (row: RoomSummary) => RoomSummary | undefined): unknown {
  const rows = (items: readonly unknown[]) => {
    let changed = false
    const next = items.map(item => {
      const updated = isRoomSummary(item) ? read(item) : undefined
      if (updated) changed = true
      return updated ?? item
    })
    return changed ? next : undefined
  }
  if (Array.isArray(data)) return rows(data)
  if (!isRecord(data)) return undefined
  if (Array.isArray(data.conversations)) {
    const conversations = rows(data.conversations)
    return conversations && { ...data, conversations }
  }
  if (Array.isArray(data.pages)) {
    let changed = false
    const pages = data.pages.map(page => {
      const updated = readRooms(page, read)
      if (updated) changed = true
      return updated ?? page
    })
    return changed ? { ...data, pages } : undefined
  }
  return undefined
}

function isRoomSummary(value: unknown): value is RoomSummary {
  return (
    isRecord(value) &&
    typeof value.id === 'string' &&
    typeof value.rowStatus === 'string' &&
    typeof value.lastMessageSeq === 'number' &&
    isRecord(value.viewer) &&
    typeof value.viewer.lastReadSeq === 'number'
  )
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

/** Agent directory mutations refresh Pod Chat, Meta Ankole, and Pod Settings together. */
export async function refreshAgentQueries(client: QueryClient): Promise<void> {
  await Promise.all([
    refreshQuery(client, podKeys.agents),
    refreshQuery(client, podKeys.conversations, false),
    refreshQuery(client, metaKeys.agents(), false),
    refreshQuery(client, ['pod-admin-agents'])
  ])
}

/** Member profile mutations refresh session, directory, and conversation displays without refetching Page/Base data. */
export async function refreshMemberProfileQueries(client: QueryClient): Promise<void> {
  await Promise.all([
    refreshQuery(client, ['pod-session'], false),
    refreshQuery(client, ['pod-me']),
    refreshQuery(client, ['pod-admin-members']),
    refreshQuery(client, podKeys.conversations, false)
  ])
}

/** Space profile mutations refresh the session header/account switcher and Space Settings together. */
export async function refreshSpaceProfileQueries(client: QueryClient): Promise<void> {
  await Promise.all([refreshQuery(client, ['pod-session'], false), refreshQuery(client, ['pod-admin-settings'])])
}

async function refreshQuery(client: QueryClient, queryKey: QueryKey, exact = true): Promise<void> {
  const filter = { queryKey, exact }
  // A page the user asked for finishes first, so the refetch below rereads it with every loaded page.
  await Promise.all(
    client
      .getQueryCache()
      .findAll(filter)
      .filter(query => query.state.fetchStatus === 'fetching' && query.state.fetchMeta?.fetchMore)
      .map(query => query.promise?.catch(() => undefined))
  )
  // Invalidation alone can reuse a pending first GET with no cached data.
  await client.cancelQueries(filter)
  await client.invalidateQueries(filter)
}
