import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { createReadDenials } from '@ankole/applet-sdk'
import { createBaseAPI } from './base-api'
import { isRealtimeAccessDenied, PodRealtime } from './realtime'
import { podLocation } from '../common/browser-context'
import { contentKeys } from './content-api'
import { applyTreeChange, updatePageMetadata } from './state/navigation-cache'
import { revalidateMentions } from './state/document-mentions'
import { podKeys } from './api'

const ContentContext = createContext<ReturnType<typeof createContent> | null>(null)
export const ContentScope = ContentContext.Provider
function createContent(client: ReturnType<typeof useQueryClient>) {
  const realtime = new PodRealtime()
  const readDenials = createReadDenials(client.getQueryCache())
  return {
    realtime,
    base: createBaseAPI(client, realtime),
    readDenial: readDenials.get,
    dispose() {
      readDenials.dispose()
      realtime.dispose()
    },
    pageHref(id: string) {
      const target = podLocation(`/pages/${id}`)
      return target.pathname + target.search
    }
  }
}

export function ContentProvider({ children }: { children: ReactNode }) {
  const client = useQueryClient()
  const [value, setValue] = useState<ReturnType<typeof createContent> | null>(null)
  useEffect(() => {
    const content = createContent(client)
    let disposed = false
    let retry: ReturnType<typeof setTimeout> | undefined
    const refreshConversations = () => {
      if (!disposed) void client.invalidateQueries({ queryKey: [...podKeys.conversations, 'recent'] })
    }
    const refresh = () => {
      if (disposed) return
      // Preserve initial reads; revalidate cached data when subscriptions become ready.
      void client.invalidateQueries({ queryKey: contentKeys.all })
      revalidateMentions(client)
      refreshConversations()
    }
    const subscribe = () => {
      void content.realtime.join('content').then(
        handle => {
          if (disposed) return handle.close()
          handle.on('access_changed', refresh)
          handle.on('rejoined', refresh)
          handle.on('tree_changed', payload => {
            if (!disposed) void applyTreeChange(client, payload)
          })
          handle.on('page_updated', payload => {
            if (disposed) return
            updatePageMetadata(client, payload)
          })
          handle.on('access_revoked', refresh)
          handle.on('conversations_changed', refreshConversations)
          void handle.ready.then(refresh, () => {})
        },
        error => {
          if (!disposed && !isRealtimeAccessDenied(error)) retry = setTimeout(subscribe, 1000)
        }
      )
    }
    subscribe()
    setValue(content)
    return () => {
      disposed = true
      clearTimeout(retry)
      content.dispose()
    }
  }, [client])
  return value && <ContentContext value={value}>{children}</ContentContext>
}

export function useContent() {
  const value = useContext(ContentContext)
  if (!value) throw new Error('Pod content provider is missing')
  return value
}
