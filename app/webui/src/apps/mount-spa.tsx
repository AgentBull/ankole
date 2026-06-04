import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { createRoot } from 'react-dom/client'
import { BullXI18nextProvider } from '@/i18n/provider'
import '@/globals.css'

/**
 * Mounts one of the server-selected SPA entries.
 *
 * The three SPAs are separate browser entrypoints for server-side cookie-session
 * gates, but they should share the same client bootstrap contract: i18n,
 * React Query defaults, and the root DOM lookup.
 */
export function mountSpa(app: ReactNode): void {
  const container = document.getElementById('root')
  if (!container) return

  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: 1,
        refetchOnWindowFocus: false,
        staleTime: 15_000
      }
    }
  })

  createRoot(container).render(
    <BullXI18nextProvider>
      <QueryClientProvider client={queryClient}>{app}</QueryClientProvider>
    </BullXI18nextProvider>
  )
}
