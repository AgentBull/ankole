import type { MutationCache } from '@tanstack/react-query'
import { StrictMode } from 'react'
import type { ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { rootErrorOptions } from './error-boundary'
import { installExternalTranslationGuard } from './external-translation-guard'
import i18n, { activeLocale, loadLocale } from './i18n'
import { getPodRuntimeBootstrap } from './pod-bootstrap'
import { AppProviders, createQueryClient } from './providers'
import { initializeFeatures } from './features'
import './styles.css'

type AppFactory = (queryClient: ReturnType<typeof createQueryClient>) => ReactNode

export type MountAppBootstrap = {
  activePlugins?: string[]
  features?: Record<string, boolean>
  locale?: string
}

type AppContainer = HTMLElement & {
  __ankoleQueryClient?: ReturnType<typeof createQueryClient>
  __ankoleRoot?: Root
}

export async function mountApp(
  children: ReactNode | AppFactory,
  {
    mutationCache,
    bootstrap
  }: {
    mutationCache?: MutationCache
    bootstrap?: MountAppBootstrap
  } = {}
) {
  const container = document.getElementById('ankole-app') as AppContainer | null
  // A missing container means the route did not come from the Phoenix shell.
  // Returning quietly keeps tests and story-like embeds from crashing.
  if (!container) return

  installExternalTranslationGuard(document)

  const runtime = getPodRuntimeBootstrap()
  const resolvedLocale = bootstrap?.locale ?? runtime?.locale
  if (resolvedLocale && document.documentElement) {
    document.documentElement.lang = resolvedLocale
  }

  // Translations must be in memory before the first render, or every string
  // would flash as its raw key. The fallback catalog loads alongside the
  // active one so missing keys resolve without a second wait.
  const activePlugins: string[] =
    bootstrap?.activePlugins ??
    runtime?.activePlugins ??
    JSON.parse(document.querySelector('meta[name="ankole-active-plugins"]')?.getAttribute('content') ?? '[]')
  const flags: Record<string, boolean> =
    bootstrap?.features ??
    runtime?.features ??
    JSON.parse(document.querySelector('meta[name="ankole-features"]')?.getAttribute('content') ?? '{}')
  const localeToLoad = resolvedLocale ?? activeLocale()
  await Promise.all([loadLocale(localeToLoad), loadLocale('en-US'), initializeFeatures(flags)])
  if (i18n.isInitialized && i18n.language !== localeToLoad) {
    await i18n.changeLanguage(localeToLoad)
  }

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
