import { describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query'
import type { ConversationDetail } from '../api'
import { podKeys } from '../api'
import { acceptConversationResult, refreshConversationQueries, refreshConversationDetail } from '../query-cache'
import {
  reloadConversation,
  subscribeConversationEvents,
  type ConversationEventStream
} from '../use-conversation-events'
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
    activities: [
      {
        agentUID: 'agent',
        conversationID: 'conversation',
        sessionID: 'conversation:conversation',
        epoch: 1,
        revision: 1,
        state: withReply ? 'settled' : 'active',
        signalID: 'signal-1',
        responseID: 'response-1',
        phase: null,
        tools: []
      }
    ],
    pendingQueues: [
      {
        agentUID: 'agent',
        queueVersion: 'initial',
        paused: false,
        inputs: [],
        workStatus: { state: withReply ? 'idle' : 'running', retryAt: null }
      }
    ],
    pendingInteractions: [],
    linkedRuns: [],
    artifacts: { pageIDs: [], attachments: [] },
    conversation: {
      accessScope: 'participants',
      canDelete: true,
      canManage: true,
      roomMode: 'dm',
      titleCustomized: false,
      createdBy: 'person',
      lastMessageSeq: 1,
      rowStatus: 'idle',
      viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 1 },
      agents: [{ uid: 'agent', displayName: 'Agent', active: true, type: 'agent', mayIntervene: true }],
      participants: [
        { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
        { uid: 'agent', displayName: 'Agent', active: true, type: 'agent', mayIntervene: true }
      ],
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
        authorDisplayName: 'Fixture author',
        authorArchived: false,
        mentions: [],
        savedPages: [],
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
              authorDisplayName: 'Fixture author',
              authorArchived: false,
              mentions: [],
              savedPages: [],
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
    ]
  }
}

describe('Pod remote cache ordering', () => {
  test('edit recovery follows an event replacement read and never adopts its cancelled snapshot', async () => {
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), detail(false))
    const oldRead = Promise.withResolvers<ConversationDetail>()
    const freshRead = Promise.withResolvers<ConversationDetail>()
    const oldStarted = Promise.withResolvers<void>()
    const freshStarted = Promise.withResolvers<void>()
    let reads = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      queryFn: () => {
        if (++reads === 1) {
          oldStarted.resolve()
          return oldRead.promise
        }
        freshStarted.resolve()
        return freshRead.promise
      }
    })
    const unsubscribe = query.subscribe(() => {})
    try {
      let recovered = false
      const recovery = refreshConversationDetail(queryClient, 'conversation').then(result => {
        recovered = true
        return result
      })
      await oldStarted.promise
      const event = refreshConversationQueries(queryClient, 'conversation')
      await freshStarted.promise
      await Promise.resolve()
      expect(recovered).toBe(false)
      const latest = detail(true)
      latest.pendingQueues[0]!.queueVersion = 'fresh-event-version'
      freshRead.resolve(latest)
      expect(await recovery).toEqual(latest)
      await event
      oldRead.resolve(detail(false))
      await oldRead.promise
      expect(queryClient.getQueryData(podKeys.detail('conversation'))).toEqual(latest)
      expect(reads).toBe(2)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('edit recovery propagates a real read failure', async () => {
    const queryClient = client()
    const failure = new Error('History request failed')
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      enabled: false,
      queryFn: () => Promise.reject(failure)
    })
    const unsubscribe = query.subscribe(() => {})
    try {
      await query.refetch()
      await expect(refreshConversationDetail(queryClient, 'conversation')).rejects.toBe(failure)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('a committed update can replace a recovery read without exposing cancellation as a history failure', async () => {
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), detail(false))
    const oldRead = Promise.withResolvers<ConversationDetail>()
    const started = Promise.withResolvers<void>()
    const latest = detail(true)
    latest.pendingQueues[0]!.queueVersion = 'committed-version'
    let reads = 0
    const query = new QueryObserver(queryClient, {
      queryKey: podKeys.detail('conversation'),
      queryFn: () => {
        if (++reads === 1) {
          started.resolve()
          return oldRead.promise
        }
        return Promise.resolve(latest)
      }
    })
    const errors: unknown[] = []
    const unsubscribe = query.subscribe(result => {
      if (result.isError) errors.push(result.error)
    })
    try {
      const recovery = refreshConversationDetail(queryClient, 'conversation')
      void recovery.catch(() => {})
      await started.promise
      await acceptConversationResult(queryClient, latest)
      await refreshConversationQueries(queryClient, 'conversation')
      expect(await recovery).toEqual(latest)
      expect(errors).toEqual([])
      oldRead.resolve(detail(false))
      await oldRead.promise
      expect(queryClient.getQueryData(podKeys.detail('conversation'))).toEqual(latest)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('older windows keep current queue state and later reads replace changed or removed statements', () => {
    const window = (first: number, last: number) => {
      const data = detail(true)
      return {
        ...data,
        pendingQueues: data.pendingQueues.map(queue => ({ ...queue, queueVersion: String(last) })),
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
    expect(expanded.pendingQueues[0]!.queueVersion).toBe('1000')
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
    const result = detail(true)
    result.pendingQueues[0]!.paused = true
    result.pendingQueues[0]!.queueVersion = 'stopped'
    await acceptConversationResult(queryClient, result)
    expect(queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.pendingQueues[0]!.paused).toBe(
      true
    )
    queryClient.clear()
  })
  test('an idle read for a previous Response cannot clear a newly started live reply', async () => {
    const queryClient = client()
    queryClient.setQueryData(podKeys.detail('conversation'), detail(true))
    const model = new ChatModel()
    model.started('response-1', ['signal-1'], 'agent')
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
      model.started('response-2', ['signal-2'], 'agent')
      model.delta('response-2', 'Current reply', ['signal-2'], 'agent')
      const currentReload = reloadConversation(queryClient, 'conversation', model)
      await currentStarted.promise
      await oldReload
      expect(model.liveStreams.value.agent?.text).toBe('Current reply')
      oldRead.resolve(detail(true))
      currentRead.resolve(detail(false))
      await currentReload
      expect(model.liveStreams.value.agent?.text).toBe('Current reply')
      expect(model.liveStreams.value.agent?.responseID).toBe('response-2')
      const silentReload = reloadConversation(queryClient, 'conversation', model)
      await silentReload
      expect(model.liveStreams.value.agent).toBeUndefined()
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
      expect(
        queryClient.getQueryData<ConversationDetail>(podKeys.detail('conversation'))?.pendingQueues[0]!.workStatus.state
      ).toBe('idle')
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

  test('SSE listeners ignore malformed and non-object payloads without throwing', () => {
    const queryClient = client()
    const model = new ChatModel()
    class FakeEventSource extends EventTarget implements ConversationEventStream {
      onopen: ConversationEventStream['onopen'] = null
      onerror: ConversationEventStream['onerror'] = null
      closed = false
      close() {
        this.closed = true
      }
    }
    const stream = new FakeEventSource()
    const unsubscribe = subscribeConversationEvents(stream, 'conversation', model, queryClient, () => {})
    try {
      for (const type of ['started', 'snapshot', 'delta', 'reasoning_delta', 'activity']) {
        for (const data of ['{bad json', 'null', '123', '"plain"', '[1, 2]']) {
          expect(() => stream.dispatchEvent(new MessageEvent(type, { data }))).not.toThrow()
        }
      }
      expect(model.liveStreams.value).toEqual({})
      expect(model.activities.value).toEqual({})

      stream.dispatchEvent(
        new MessageEvent('delta', {
          data: JSON.stringify({
            conversationID: 'conversation',
            agentUID: 'agent',
            responseID: 'response-1',
            signalIDs: ['signal-1'],
            text: 'Hello'
          })
        })
      )
      expect(model.liveStreams.value.agent?.text).toBe('Hello')
    } finally {
      unsubscribe()
      expect(stream.closed).toBe(true)
      queryClient.clear()
    }
  })
})
