import { StrictMode } from 'react'
import type { ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { activeLocale, loadLocale } from './i18n'
import { AppProviders, createQueryClient } from './providers'
import '@ankole/uikit/styles.css'
import './styles.css'

type AppFactory = (queryClient: ReturnType<typeof createQueryClient>) => ReactNode

type AppContainer = HTMLElement & {
  __ankoleQueryClient?: ReturnType<typeof createQueryClient>
  __ankoleRoot?: Root
}

/** Mounts a React tree into the Phoenix-provided `#ankole-app` container. */
export async function mountApp(children: ReactNode | AppFactory) {
  const container = document.getElementById('ankole-app') as AppContainer | null
  // A missing container means the route did not come from the Phoenix shell.
  // Returning quietly keeps tests and story-like embeds from crashing.
  if (!container) return

  // Translations must be in memory before the first render, or every string
  // would flash as its raw key. The fallback catalog loads alongside the
  // active one so missing keys resolve without a second wait.
  await Promise.all([loadLocale(activeLocale()), loadLocale('en-US')])

  const queryClient = container.__ankoleQueryClient ?? createQueryClient()
  const root = container.__ankoleRoot ?? createRoot(container)

  container.__ankoleQueryClient = queryClient
  container.__ankoleRoot = root

  const app = typeof children === 'function' ? children(queryClient) : children

  root.render(
    <StrictMode>
      <AppProviders queryClient={queryClient}>{app}</AppProviders>
    </StrictMode>
  )
}
