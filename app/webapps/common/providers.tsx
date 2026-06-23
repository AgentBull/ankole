import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { HelmetProvider } from 'react-helmet-async'
import { I18nextProvider } from 'react-i18next'
import i18n from './i18n'

/** Creates the query client defaults shared by every SPA entrypoint. */
export function createQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        refetchOnWindowFocus: false,
        // The setup/auth pages mostly read stable local state. One retry handles
        // short server startup races without hiding persistent API errors.
        retry: 1,
        staleTime: 15_000
      }
    }
  })
}

/** Provides shared document-head, i18n, and data-fetching context. */
export function AppProviders({ children, queryClient }: { children: ReactNode; queryClient: QueryClient }) {
  return (
    <HelmetProvider>
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
      </I18nextProvider>
    </HelmetProvider>
  )
}
