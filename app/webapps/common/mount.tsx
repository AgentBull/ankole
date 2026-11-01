import type { MutationCache } from '@tanstack/react-query'
import { StrictMode } from 'react'
import type { ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { rootErrorOptions } from './error-boundary'
import { installExternalTranslationGuard } from './external-translation-guard'
import { activeLocale, loadLocale } from './i18n'
import { AppProviders, createQueryClient } from './providers'
import { initializeFeatures } from './features'
import './styles.css'

type AppFactory = (queryClient: ReturnType<typeof createQueryClient>) => ReactNode

type AppContainer = HTMLElement & {
  __ankoleQueryClient?: ReturnType<typeof createQueryClient>
  __ankoleRoot?: Root
}

export async function mountApp(
  children: ReactNode | AppFactory,
  { mutationCache }: { mutationCache?: MutationCache } = {}
) {
  const container = document.getElementById('ankole-app') as AppContainer | null
  // A missing container means the route did not come from the Phoenix shell.
  // Returning quietly keeps tests and story-like embeds from crashing.
  if (!container) return

  installExternalTranslationGuard(document)

  // Translations must be in memory before the first render, or every string
  // would flash as its raw key. The fallback catalog loads alongside the
  // active one so missing keys resolve without a second wait.
  const activePlugins: string[] = JSON.parse(
    document.querySelector('meta[name="ankole-active-plugins"]')?.getAttribute('content') ?? '[]'
  )
  const flags: Record<string, boolean> = JSON.parse(
    document.querySelector('meta[name="ankole-features"]')?.getAttribute('content') ?? '{}'
  )
  await Promise.all([loadLocale(activeLocale()), loadLocale('en-US'), initializeFeatures(flags)])

  const queryClient = container.__ankoleQueryClient ?? createQueryClient(mutationCache)
  const root = container.__ankoleRoot ?? createRoot(container, rootErrorOptions)

  container.__ankoleQueryClient = queryClient
  container.__ankoleRoot = root

  const app = typeof children === 'function' ? children(queryClient) : children

  root.render(
    <StrictMode>
      <AppProviders queryClient={queryClient} activePlugins={activePlugins}>
        {app}
      </AppProviders>
    </StrictMode>
  )
}
