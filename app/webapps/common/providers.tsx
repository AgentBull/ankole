import { ThemeProvider } from '@ankole/uikit/components/theme-provider'
import { Toaster } from '@ankole/uikit/components/sonner'
import { QueryClient, QueryClientProvider, type MutationCache } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { HelmetProvider } from 'react-helmet-async'
import { I18nextProvider } from 'react-i18next'
import i18n from './i18n'

/** Creates the query client defaults shared by every SPA entrypoint. */
export function createQueryClient(mutationCache?: MutationCache) {
  return new QueryClient({
    mutationCache,
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

export function AppProviders({ children, queryClient }: { children: ReactNode; queryClient: QueryClient }) {
  return (
    <ThemeProvider>
      <HelmetProvider>
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={queryClient}>
            {children}
            <Toaster />
          </QueryClientProvider>
        </I18nextProvider>
      </HelmetProvider>
    </ThemeProvider>
  )
}
