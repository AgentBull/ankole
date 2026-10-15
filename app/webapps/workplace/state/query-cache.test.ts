import { describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query'
import type { ConversationDetail } from '../api'
import { workplaceKeys } from '../api'
import { refreshConversationQueries } from '../query-cache'
import { reloadConversation } from '../use-conversation-events'
import { ChatModel } from './chat'

function client() {
  return new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
  })
}

function detail(withReply: boolean): ConversationDetail {
  return {
    conversation: {
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
              text: 'Reply',
              createdAt: '2026-10-14T00:00:01Z',
              replyToMessageID: 'question',
              signalID: 'signal-1'
            }
          ]
        : [])
    ],
    status: { state: withReply ? 'idle' : 'running', retryAt: null }
  }
}

describe('Workplace remote cache ordering', () => {
  test('an idle read for a previous Response cannot clear a newly started live reply', async () => {
    const queryClient = client()
    queryClient.setQueryData(workplaceKeys.detail('conversation'), detail(true))
    const model = new ChatModel()
    model.started('response-1', ['signal-1'])
    const oldRead = Promise.withResolvers<ConversationDetail>()
    const currentRead = Promise.withResolvers<ConversationDetail>()
    const oldStarted = Promise.withResolvers<void>()
    const currentStarted = Promise.withResolvers<void>()
    let calls = 0
    const query = new QueryObserver(queryClient, {
      queryKey: workplaceKeys.detail('conversation'),
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
      queryKey: workplaceKeys.detail('conversation'),
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
      expect(queryClient.getQueryData(workplaceKeys.detail('conversation'))).toBeUndefined()
      const refreshed = refreshConversationQueries(queryClient, 'conversation')
      await started.promise
      expect(calls).toBe(2)
      fresh.resolve(detail(true))
      await refreshed
      first.resolve(detail(false))
      await first.promise
      await Promise.resolve()
      expect(
        queryClient.getQueryData<ConversationDetail>(workplaceKeys.detail('conversation'))?.messages.at(-1)?.id
      ).toBe('reply')
      expect(query.getCurrentResult().isStale).toBe(false)
    } finally {
      unsubscribe()
      queryClient.clear()
    }
  })

  test('a late POST acknowledgement preserves an already read reply while the fresh GET is pending', async () => {
    const queryClient = client()
    const complete = detail(true)
    queryClient.setQueryData(workplaceKeys.detail('conversation'), complete)
    const fresh = Promise.withResolvers<ConversationDetail>()
    const query = new QueryObserver(queryClient, {
      queryKey: workplaceKeys.detail('conversation'),
      queryFn: () => fresh.promise
    })
    const observations: number[] = []
    const unsubscribe = query.subscribe(result => observations.push(result.data?.messages.length ?? 0))
    const post = Promise.withResolvers<ConversationDetail>()
    const started = Promise.withResolvers<void>()
    const mutation = new MutationObserver(queryClient, {
      mutationFn: () => post.promise,
      onSuccess: data => {
        const refreshing = refreshConversationQueries(queryClient, data.conversation.id)
        started.resolve()
        return refreshing
      }
    })
    try {
      const submitted = mutation.mutate()
      post.resolve(detail(false))
      await started.promise
      expect(queryClient.getQueryData<ConversationDetail>(workplaceKeys.detail('conversation'))?.messages).toEqual(
        complete.messages
      )
      fresh.resolve(complete)
      await submitted
      expect(observations.every(count => count === 2)).toBe(true)
      expect(queryClient.getQueryData<ConversationDetail>(workplaceKeys.detail('conversation'))?.status.state).toBe(
        'idle'
      )
    } finally {
      unsubscribe()
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
      queryKey: workplaceKeys.conversations,
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
