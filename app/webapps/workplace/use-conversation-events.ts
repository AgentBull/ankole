import { useQueryClient, type QueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { conversationEventsURL, workplaceKeys, type ConversationDetail } from './api'
import type { ChatModel } from './state/chat'
import { refreshConversationQueries } from './query-cache'

export function useConversationEvents(id: string | undefined, model: InstanceType<typeof ChatModel>) {
  const client = useQueryClient()
  useEffect(() => {
    if (!id) return
    const events = new EventSource(conversationEventsURL(id))
    const reload = () => {
      void reloadConversation(client, id, model)
    }
    events.onopen = () => {
      model.connected()
      reload()
    }
    events.onerror = () => {
      model.disconnected()
      reload()
    }
    events.addEventListener('started', event => {
      const payload: unknown = JSON.parse((event as MessageEvent<string>).data)
      if (!responsePayload(payload)) return
      model.started(payload.responseID, payload.signalIDs)
      reload()
    })
    events.addEventListener('delta', event => {
      const payload: unknown = JSON.parse((event as MessageEvent<string>).data)
      if (responsePayload(payload) && 'text' in payload && typeof payload.text === 'string') {
        model.delta(payload.responseID, payload.text, payload.signalIDs)
      }
    })
    events.addEventListener('message', reload)
    events.addEventListener('status', reload)
    return () => events.close()
  }, [client, id, model])
}

function responsePayload(payload: unknown): payload is { responseID: string; signalIDs: string[] } {
  return (
    !!payload &&
    typeof payload === 'object' &&
    'responseID' in payload &&
    typeof payload.responseID === 'string' &&
    'signalIDs' in payload &&
    Array.isArray(payload.signalIDs) &&
    payload.signalIDs.every(id => typeof id === 'string')
  )
}

/** Bind a fresh execution status to the Response that requested the read. */
export async function reloadConversation(
  client: QueryClient,
  id: string,
  model: InstanceType<typeof ChatModel>
): Promise<void> {
  const responseID = model.live.peek()?.responseID
  await refreshConversationQueries(client, id)
  const result = client.getQueryState<ConversationDetail>(workplaceKeys.detail(id))
  if (result?.status === 'success' && result.fetchStatus === 'idle' && result.data) {
    model.reconcileStatus(responseID, result.data.status)
  }
}
