import { isRecord, recordValue, safeJsonParse } from '@agentbull/active-support'
import { useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useEffect, useRef } from 'react'
import { podLocation } from '../common/browser-context'
import { conversationEventsURL, podKeys, type ConversationDetail, type PodActivity } from './api'
import type { ChatModel } from './state/chat'
import { hasUnsentChatWork } from './state/chat-drafts'
import { refreshConversationQueries } from './query-cache'

export function useConversationEvents(
  id: string | undefined,
  model: InstanceType<typeof ChatModel>,
  onExitConversation?: () => void
) {
  const client = useQueryClient(),
    navigate = useNavigate()
  const exitRef = useRef(onExitConversation)
  exitRef.current = onExitConversation
  useEffect(() => {
    if (!id) return
    return subscribeConversationEvents(new EventSource(conversationEventsURL(id)), id, model, client, () => {
      if (exitRef.current) exitRef.current()
      else void navigate({ to: podLocation('/').pathname })
    })
  }, [client, id, model, navigate])
}

export type ConversationEventStream = Pick<EventTarget, 'addEventListener'> & {
  close: () => void
  onopen: ((this: EventSource, ev: Event) => unknown) | null
  onerror: ((this: EventSource, ev: Event) => unknown) | null
}

export function subscribeConversationEvents(
  events: ConversationEventStream,
  id: string,
  model: InstanceType<typeof ChatModel>,
  client: QueryClient,
  onExit: () => void
): () => void {
  let revoked = false
  const reload = () => {
    if (!revoked) void reloadConversation(client, id, model)
  }
  events.onopen = () => {
    model.connected()
    reload()
  }
  events.onerror = () => {
    if (!revoked) {
      model.disconnected()
      reload()
    }
  }
  events.addEventListener('started', event => {
    const payload = recordValue(safeJsonParse((event as MessageEvent<string>).data).unwrapOr(undefined))
    if (!responsePayload(payload) || payload.conversationID !== id) return
    model.started(payload.responseID, payload.signalIDs, payload.agentUID, payload.agentName, payload.turnStartedAt)
    reload()
  })
  events.addEventListener('snapshot', event => {
    const payload = recordValue(safeJsonParse((event as MessageEvent<string>).data).unwrapOr(undefined))
    if (
      !responsePayload(payload) ||
      payload.conversationID !== id ||
      typeof payload.text !== 'string' ||
      typeof payload.thinkingSummary !== 'string'
    ) {
      return
    }
    model.snapshot({
      agentUID: payload.agentUID,
      agentName: payload.agentName,
      responseID: payload.responseID,
      signalIDs: payload.signalIDs,
      text: payload.text,
      thinkingSummary: payload.thinkingSummary,
      startedAt: payload.turnStartedAt
    })
  })
  for (const type of ['delta', 'reasoning_delta']) {
    events.addEventListener(type, event => {
      const payload = recordValue(safeJsonParse((event as MessageEvent<string>).data).unwrapOr(undefined))
      if (responsePayload(payload) && payload.conversationID === id && typeof payload.text === 'string') {
        model.delta(payload.responseID, payload.text, payload.signalIDs, payload.agentUID, type === 'reasoning_delta')
      }
    })
  }
  events.addEventListener('activity', event => {
    const payload = recordValue(safeJsonParse((event as MessageEvent<string>).data).unwrapOr(undefined))
    if (activityPayload(payload) && payload.conversationID === id) model.observeActivity(payload)
  })
  events.addEventListener('conversation', reload)
  events.addEventListener('access_revoked', () => {
    revoked = true
    events.close()
    model.markGone()
    void client
      .cancelQueries({ queryKey: podKeys.detail(id) })
      .then(() => client.removeQueries({ queryKey: podKeys.detail(id) }))
    void client.invalidateQueries({ queryKey: podKeys.conversations })
    if (!hasUnsentChatWork(model)) onExit()
  })
  return () => events.close()
}

type ResponseFrame = {
  conversationID: string
  agentUID: string
  responseID: string
  signalIDs: string[]
  agentName?: string
  turnStartedAt?: string
  text?: string
  thinkingSummary?: string
}
function responsePayload(payload: unknown): payload is ResponseFrame {
  if (!isRecord(payload)) return false
  const item = payload as ResponseFrame
  return (
    typeof item.conversationID === 'string' &&
    typeof item.agentUID === 'string' &&
    typeof item.responseID === 'string' &&
    Array.isArray(item.signalIDs) &&
    item.signalIDs.every(id => typeof id === 'string')
  )
}

export async function reloadConversation(
  client: QueryClient,
  id: string,
  model: InstanceType<typeof ChatModel>
): Promise<void> {
  const streams = { ...model.liveStreams.peek() }
  await refreshConversationQueries(client, id)
  const result = client.getQueryState<ConversationDetail>(podKeys.detail(id))
  if (result?.status === 'success' && result.fetchStatus === 'idle' && result.data) {
    for (const stream of Object.values(streams)) {
      const work = result.data.pendingQueues.find(item => item.agentUID === stream.agentUID)
      if (work?.workStatus.state === 'idle') {
        model.settled(stream.responseID, stream.agentUID)
      }
    }
  }
}

function activityPayload(value: unknown): value is PodActivity {
  if (!isRecord(value)) return false
  const item = value as PodActivity
  return (
    typeof item.conversationID === 'string' &&
    typeof item.agentUID === 'string' &&
    typeof item.sessionID === 'string' &&
    Number.isSafeInteger(item.epoch) &&
    Number.isSafeInteger(item.revision) &&
    ['active', 'unavailable', 'settled'].includes(item.state) &&
    Array.isArray(item.tools)
  )
}
