import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { createDatabaseAPI } from './database-api'
import { PodRealtime } from './realtime'
import { podLocation } from '../common/browser-context'

const ContentContext = createContext<ReturnType<typeof createContent> | null>(null)
export const ContentScope = ContentContext.Provider
function createContent(client: ReturnType<typeof useQueryClient>) {
  const realtime = new PodRealtime()
  return {
    realtime,
    database: createDatabaseAPI(client, realtime),
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
    setValue(content)
    return () => content.realtime.dispose()
  }, [client])
  return value && <ContentContext value={value}>{children}</ContentContext>
}

export function useContent() {
  const value = useContext(ContentContext)
  if (!value) throw new Error('Pod content provider is missing')
  return value
}
