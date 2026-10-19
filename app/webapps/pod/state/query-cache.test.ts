import { describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query'
import type { ConversationDetail } from '../api'
import { podKeys } from '../api'
import { acceptConversationResult, refreshConversationQueries } from '../query-cache'
import { reloadConversation } from '../use-conversation-events'
import { ChatModel } from './chat'
import { mergeMessageWindow } from './message-history'

function client() {
  return new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
  })
}

function detail(withReply: boolean): ConversationDetail {
  return {
    removedMessageIDs: [],
    olderMessagesBeforeSeq: null,
    messageRange: { firstSeq: 1, lastSeq: withReply ? 2 : 1 },
    pendingInputs: [],
    queuePaused: false,
    queueVersion: 'initial',
    retryableMessageID: null,
    conversation: {
      pageID: null,
      id: 'conversation',
      title: 'Question',
      agent: { uid: 'agent', displayName: 'Agent', active: true },
      lastActivityAt: '2026-10-14T00:00:00Z'
    },
    messages: [
      {
        id: 'question',
        seq: 1,
        authorType: 'human',
        authorUID: 'person',
        kind: 'message',
        links: [],
        attachments: [],
        text: 'Question',
        createdAt: '2026-10-14T00:00:00Z',
        replyToMessageID: null,
        signalID: null
      },
      ...(withReply
        ? [
            {
              id: 'reply',
              seq: 2,
              authorType: 'agent' as const,
              authorUID: 'agent',
              kind: 'message' as const,
              links: [],
              attachments: [],
              text: 'Reply',
              createdAt: '2026-10-14T00:00:01Z',
              replyToMessageID: 'question',
              signalID: 'signal-1'
            }
          ]
        : [])
    ],
    status: {
      state: withReply ? 'idle' : 'running',
      retryAt: null,
      activity: {
        conversationID: 'conversation',
        agentUID: 'agent',
        sessionID: 'conversation:conversation',
        signalID: null,
        responseID: null,
        epoch: 0,
        revision: 0,
        state: 'unavailable',
        phase: null,
        tools: []
      }
    }
  }
}

describe('Pod remote cache ordering', () => {
  test('older windows keep current queue state and later reads replace changed or removed statements', () => {
    const window = (first: number, last: number) => {
      const data = detail(true)
      return {
        ...data,
        queueVersion: String(last),
        olderMessagesBeforeSeq: first > 1 ? first : null,
        messageRange: { firstSeq: first, lastSeq: last },
        messages: Array.from({ length: last - first + 1 }, (_, index) => ({
          ...data.messages[0]!,
          id: `message-${first + index}`,
          seq: first + index,
          text: `Statement ${first + index}`
        }))
      }
    }
    const current = window(501, 1000)
    const expanded = mergeMessageWindow(current, window(1, 500), true)
    expect(expanded.messages).toHaveLength(1000)
    expect(expanded.queueVersion).toBe('1000')
    expect(expanded.olderMessagesBeforeSeq).toBeNull()
    const next = window(502, 1001)
    next.messages = next.messages
      .filter(message => message.seq !== 950)
      .map(message => (message.seq === 900 ? { ...message, text: 'Edited statement' } : message))
    const merged = mergeMessageWindow(expanded, next)
    expect(merged.messages[0]?.seq).toBe(1)
    expect(merged.messages.at(-1)?.seq).toBe(1001)
    expect(merged.messages.find(message => message.seq === 900)?.text).toBe('Edited statement')
    expect(merged.messages.some(message => message.seq === 950)).toBe(false)
    expect(merged.messages).toHaveLength(1000)
    expect(merged.olderMessagesBeforeSeq).toBeNull()
  })

  test('a removal outside the latest window survives stale history and command responses', async () => {
    const base = detail(true)
    const loaded = {
      ...base,
      messageRange: { firstSeq: 1, lastSeq: 1000 },
      messages: Array.from({ length: 1000 }, (_, i) => ({ ...base.messages[0]!, id: `m-${i + 1}`, seq: i + 1 }))
    }
    const refresh = {
      ...base,
      messageRange: { firstSeq: 502, lastSeq: 1001 },
      messages: [{ ...base.messages[0]!, id: 'm-1001', seq: 1001 }],
      removedMessageIDs: ['m-2']
    }
    const current = mergeMessageWindow(loaded, refresh)
    expect(current.messages.some(message => message.id === 'm-2')).toBe(false)
    const oldWindow = {
      ...loaded,
      messageRange: { firstSeq: 1, lastSeq: 500 },
      messages: loaded.messages.slice(0, 500)
    }
    const late = mergeMessageWindow(current, oldWindow, true)
    expect(late.messages.some(message => message.id === 'm-2')).toBe(false)
    expect(late.messageRange.lastSeq).toBe(1001)
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), late)
    await acceptConversationResult(queryClient, { ...oldWindow, removedMessageIDs: ['m-3'] })
    const accepted = queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))!
    expect(accepted.messages.some(message => message.id === 'm-3')).toBe(false)
    expect(accepted.messages.some(message => message.id === 'm-2')).toBe(false)
    expect(accepted.messageRange.lastSeq).toBe(1001)
    queryClient.clear()
  })

  test('an accepted queue update remains visible without a new statement or a successful follow-up read', async () => {
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), detail(true))
    const result = { ...detail(true), queuePaused: true, queueVersion: 'stopped' }
    await acceptConversationResult(queryClient, result)
    expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.queuePaused).toBe(true)
    queryClient.clear()
  })
  test('an idle read for a previous Response cannot clear a newly started live reply', async () => {
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), detail(true))
    const model = new ChatModel()
    model.started('response-1', ['signal-1'])
    const oldRead = Promise.withResolvers<ConversationDetail>()
    const currentRead = Promise.withResolvers<ConversationDetail>()
    const oldStarted = Promise.withResolvers<void>()
    const currentStarted = Promise.withResolvers<void>()
    let calls = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      queryFn: () => {
        calls += 1
        if (calls === 1) {
          oldStarted.resolve()
          return oldRead.promise
        }
        if (calls > 2) return Promise.resolve(detail(true))
        currentStarted.resolve()
        return currentRead.promise
      }
    })
    const unsubscribe = query.subscribe(() => {})
    try {
      const oldReload = reloadConversation(queryClient, 'conversation', model)
      await oldStarted.promise
      model.started('response-2', ['signal-2'])
      model.delta('response-2', 'Current reply', ['signal-2'])
      const currentReload = reloadConversation(queryClient, 'conversation', model)
      await currentStarted.promise
      await oldReload
      expect(model.live.value?.text).toBe('Current reply')
      oldRead.resolve(detail(true))
      currentRead.resolve(detail(false))
      await currentReload
      expect(model.live.value?.text).toBe('Current reply')
      expect(model.live.value?.responseID).toBe('response-2')
      const silentReload = reloadConversation(queryClient, 'conversation', model)
      await silentReload
      expect(model.live.value).toBeUndefined()
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })
  test('an event during the first pending GET starts a fresh read and rejects the old snapshot', async () => {
    const queryClient = client()
    const first = Promise.withResolvers<ConversationDetail>()
    const fresh = Promise.withResolvers<ConversationDetail>()
    const started = Promise.withResolvers<void>()
    let calls = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      queryFn: () => {
        calls += 1
        if (calls === 1) return first.promise
        started.resolve()
        return fresh.promise
      }
    })
    const unsubscribe = query.subscribe(() => {})
    try {
      expect(calls).toBe(1)
      expect(queryClient.getQueryData(podKeys.detail('conversation'))).toBeUndefined()
      const refreshed = refreshConversationQueries(queryClient, 'conversation')
      await started.promise
      expect(calls).toBe(2)
      fresh.resolve(detail(true))
      await refreshed
      first.resolve(detail(false))
      await first.promise
      await Promise.resolve()
      expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.messages.at(-1)?.id).toBe(
        'reply'
      )
      expect(query.getCurrentResult().isStale).toBe(false)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('a late POST acknowledgement preserves an already read reply while the fresh GET is pending', async () => {
    const queryClient = client()
    const complete = detail(true)
    queryClient.setQueryData(podKeys.detail('conversation'), detail(false))
    const obsolete = Promise.withResolvers<ConversationDetail>()
    const fresh = Promise.withResolvers<ConversationDetail>()
    let reads = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      queryFn: () => (++reads === 1 ? obsolete.promise : fresh.promise)
    })
    const observations: number[] = []
    const unsubscribe = query.subscribe(result => observations.push(result.data?.messages.length ?? 0))
    const oldRead = query.refetch()
    queryClient.setQueryData(podKeys.detail('conversation'), complete)
    observations.length = 0
    const post = Promise.withResolvers<ConversationDetail>()
    const started = Promise.withResolvers<void>()
    const mutation = new MutationObserver(queryClient, {
      mutationFn: () => post.promise,
      onSuccess: async data => {
        await acceptConversationResult(queryClient, data)
        const refreshing = refreshConversationQueries(queryClient, data.conversation.id)
        started.resolve()
        return refreshing
      }
    })
    try {
      const submitted = mutation.mutate()
      post.resolve(detail(false))
      await started.promise
      expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.messages).toEqual(
        complete.messages
      )
      obsolete.resolve(detail(false))
      await oldRead
      expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.messages).toEqual(
        complete.messages
      )
      fresh.resolve(complete)
      await submitted
      expect(observations.every(count => count === 2)).toBe(true)
      expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.status.state).toBe('idle')
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('a successful POST remains visible after the optimistic message is cleared while GET is delayed', async () => {
    const queryClient = client()
    const model = new ChatModel()
    model.draft.value = 'Question'
    const submitted = model.submit('conversation', 'agent', () => 'question')
    const acknowledged = detail(false)
    try {
      await acceptConversationResult(queryClient, acknowledged)
      model.accepted(submitted)
      expect(model.pending.value).toBeUndefined()
      expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.messages).toEqual(
        acknowledged.messages
      )
    } finally {
      queryClient.clear()
    }
  })

  test('a completion event also replaces a pending first sidebar GET', async () => {
    const queryClient = client()
    const first = Promise.withResolvers<{ conversations: ConversationDetail['conversation'][] }>()
    const fresh = Promise.withResolvers<{ conversations: ConversationDetail['conversation'][] }>()
    const started = Promise.withResolvers<void>()
    let calls = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.conversations,
      queryFn: () => {
        calls += 1
        if (calls === 1) return first.promise
        started.resolve()
        return fresh.promise
      }
    })
    const unsubscribe = query.subscribe(() => {})
    try {
      const refreshed = refreshConversationQueries(queryClient, 'conversation')
      await started.promise
      expect(calls).toBe(2)
      fresh.resolve({ conversations: [detail(true).conversation] })
      await refreshed
      first.resolve({ conversations: [] })
      await first.promise
      await Promise.resolve()
      expect(query.getCurrentResult().data?.conversations).toHaveLength(1)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })
})
