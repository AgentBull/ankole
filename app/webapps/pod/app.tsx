import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { SidebarInset, SidebarProvider, SidebarTrigger, TooltipProvider, useSidebar } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import {
  createRootRoute,
  createRoute,
  createRouter,
  lazyRouteComponent,
  Outlet,
  RouterProvider,
  useLocation,
  useNavigate,
  useRouter,
  useRouterState
} from '@tanstack/react-router'
import { useQueryClient, useQueryErrorResetBoundary } from '@tanstack/react-query'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { ErrorBoundary, ErrorFallback } from '../common/error-boundary'
import { InternalAPIError } from '../common/internal-api-client'
import { PodSidebar } from './sidebar'
import { ContentListRoute } from './content-list'
import { ContentProvider } from './content-context'
import { ContentError } from './content-primitives'
import { ChatDraftProvider } from './chat-drafts'
import { podKeys, type ConversationDetail } from './api'
import { contentKeys, pageQuery, type PageDetail } from './content-api'
import { prefetchBase } from './base-api'
import { RealtimeRequestError } from './realtime'
import { podLocation, podRouteID } from '../common/browser-context'
import { parseRouterSearch, stringifyRouterSearch, useSearchParams } from '../common/router'
import { StandaloneActionCardDialog } from './chat/standalone-action-card-dialog'
import { PodCommandContext, PodCommandMenu, type PodCommandNavigationState } from './command-menu'
import { SidebarLayoutModel } from './state/sidebar-layout'
import './pod.css'

import { SlotGate, validateSlotIDs } from '../common/slots'
import { PodSlotsContext, usePodSlots, podSettingsSections, type PodAppSlots } from './slots'
export type { PodAppSlots } from './slots'

const contentScopeTitleKeys: Record<string, string> = {
  all: 'pod.content.all_pages',
  space: 'pod.content.space',
  private: 'pod.content.private',
  shared: 'pod.content.shared_with_me',
  recent: 'pod.content.recently_visited',
  favorites: 'pod.content.favorites',
  trash: 'pod.content.trash',
  search: 'pod.content.search_pages'
}

export function podRouteTitle(
  pathname: string,
  t: (key: string) => string,
  conversationTitle?: string
): string | undefined {
  if (pathname.startsWith('/pages/')) return undefined
  let label: string | undefined
  if (pathname === '/me' || pathname.startsWith('/me/')) {
    label = t('pod.account.title')
  } else if (pathname === '/settings' || pathname.startsWith('/settings/')) {
    label = t('pod.settings.title')
  } else if (pathname === '/colleagues') {
    label = t('pod.colleagues.title')
  } else if (pathname === '/') {
    label = t('pod.sidebar.tabs.chat')
  } else if (pathname.startsWith('/conversations/')) {
    label = conversationTitle?.trim() || t('pod.sidebar.tabs.chat')
  } else if (pathname.startsWith('/content/')) {
    const scope = decodeURIComponent(pathname.slice('/content/'.length).split('/')[0] ?? '')
    const key = contentScopeTitleKeys[scope]
    label = key ? t(key) : t('pod.sidebar.tabs.home')
  }
  return label ? `${label} · Ankole` : undefined
}
const routeFeedback = {
  pendingComponent: PodRouteLoading,
  pendingMs: 0,
  pendingMinMs: 0,
  errorComponent: PodRouteError
}
const LazyChatRoute = lazyRouteComponent(() => import('./chat-page'), 'ChatRoute')
const LazyPageRoute = lazyRouteComponent(() => import('./page-workspace'), 'PageRoute')

export function PodApp({ slots = {} }: { slots?: PodAppSlots } = {}) {
  validateSlotIDs(slots.settingsTabs ?? [], podSettingsSections)
  const client = useQueryClient()
  const router = useMemo(() => {
    const rootRoute = createRootRoute({ component: PodShell, errorComponent: PodShellError })
    const routeTree = rootRoute.addChildren([
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'me',
        component: lazyRouteComponent(() => import('./account-settings'), 'AccountSettings'),
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'settings',
        component: lazyRouteComponent(() => import('./pod-settings'), 'PodSettings'),
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: '/',
        validateSearch: (search: Record<string, unknown>) => ({
          agent: typeof search.agent === 'string' ? search.agent : undefined,
          actionCard: typeof search.actionCard === 'string' ? search.actionCard : undefined
        }),
        component: LazyChatRoute,
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'pages/$pageID',
        loader: async ({ params }) => {
          const pageID = podRouteID(params.pageID)
          if (!pageID) throw new Response('Page not found', { status: 404 })
          const read = client.prefetchQuery(pageQuery(pageID))
          if (client.getQueryData(contentKeys.page(pageID)) === undefined) await read
          const detail = client.getQueryData<PageDetail>(contentKeys.page(pageID))
          if (detail?.page.type === 'base') void prefetchBase(client, pageID)
          return null
        },
        component: LazyPageRoute,
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'content/$scope',
        component: ContentListRoute,
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'colleagues',
        component: lazyRouteComponent(() => import('./colleagues'), 'Colleagues'),
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'conversations/$conversationID',
        component: LazyChatRoute,
        ...routeFeedback
      })
    ])

    return createRouter({
      routeTree,
      defaultPreload: 'intent',
      defaultPreloadDelay: 250,
      defaultPreloadStaleTime: 0,
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
  }, [client])
  return (
    <PodSlotsContext value={slots}>
      <ContentProvider>
        <ChatDraftProvider>
          <RouterProvider router={router} />
        </ChatDraftProvider>
      </ContentProvider>
    </PodSlotsContext>
  )
}

function PodRouteLoading() {
  const { t } = useTranslation()
  return (
    <>
      <PodTopBar pageFallback />
      <p role="status" className="p-8">
        {t('pod.content.loading')}
      </p>
    </>
  )
}

function PodShellError({ error, reset }: { error: unknown; reset?: () => void }) {
  const router = useRouter()
  const queryReset = useQueryErrorResetBoundary()
  return (
    <ErrorFallback
      variant="shell"
      error={error}
      reset={() => {
        queryReset.reset()
        if (reset) {
          reset()
          void router.invalidate()
        } else {
          window.location.reload()
        }
      }}
    />
  )
}

function PodRouteError({ error, reset }: { error: unknown; reset?: () => void }) {
  const router = useRouter()
  const queryReset = useQueryErrorResetBoundary()
  const retry = () => {
    queryReset.reset()
    if (reset) {
      reset()
      void router.invalidate()
    } else {
      window.location.reload()
    }
  }
  const isRequestFailure =
    error instanceof InternalAPIError || error instanceof RealtimeRequestError || error instanceof Response
  return (
    <>
      <PodTopBar pageFallback />
      <div className="p-8">
        {isRequestFailure ? (
          <ContentError error={error} retry={retry} />
        ) : (
          <ErrorFallback variant="panel" error={error} reset={retry} />
        )}
      </div>
    </>
  )
}

function PodShell() {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const sidebarLayout = useModel(SidebarLayoutModel)
  const { accountNavigation } = usePodSlots()
  const { pathname, composerLocationKey } = useLocation({
    select: location => {
      const state = location.state as (Partial<PodCommandNavigationState> & { __TSR_key?: string; key?: string }) | null
      return {
        pathname: location.pathname,
        composerLocationKey:
          location.pathname === '/' && state?.focusComposer ? (state.__TSR_key ?? state.key ?? location.href) : null
      }
    },
    structuralSharing: true
  })
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const actionCardID = searchParams.get('actionCard')?.trim() || undefined
  const closeActionCardDialog = useCallback(() => {
    setSearchParams(
      prev => {
        const next = new URLSearchParams(prev)
        next.delete('actionCard')
        return next
      },
      { replace: true, preventScrollReset: true }
    )
  }, [setSearchParams])
  const [commandOpen, setCommandOpen] = useState(false)
  const commandReturnFocus = useRef<HTMLElement | null>(null)
  const focusedChatLocation = useRef<string | null>(null)
  useLayoutEffect(() => {
    const conversationSegment = pathname.startsWith('/conversations/')
      ? decodeURIComponent(pathname.slice('/conversations/'.length).split('/')[0] ?? '')
      : undefined
    const conversationID = conversationSegment ? (podRouteID(conversationSegment) ?? conversationSegment) : undefined
    const syncTitle = () => {
      let conversationTitle: string | undefined
      if (conversationID) {
        conversationTitle =
          client.getQueryData<ConversationDetail>(podKeys.detail(conversationID))?.conversation.title ||
          client
            .getQueryData<{ conversations: Array<{ id: string; title: string }> }>(podKeys.conversations)
            ?.conversations.find(item => item.id === conversationID)?.title
      }
      const next = podRouteTitle(pathname, t, conversationTitle)
      if (next) document.title = next
    }
    syncTitle()
    if (!conversationID) return
    return client.getQueryCache().subscribe(() => syncTitle())
  }, [client, pathname, t])
  const openCommand = useCallback(() => {
    commandReturnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setCommandOpen(true)
  }, [])
  useEffect(() => {
    const commandKey = (event: KeyboardEvent) =>
      !event.isComposing &&
      event.keyCode !== 229 &&
      !event.repeat &&
      !event.altKey &&
      !event.shiftKey &&
      (event.metaKey || event.ctrlKey) &&
      event.key.toLowerCase() === 'k'
    // With a text selection in an editable document, the platform shortcut edits a link first.
    const linkKey = (event: KeyboardEvent) => {
      const mac = /Mac|iPhone|iPad|iPod/.test(navigator.platform)
      if (mac ? !event.metaKey || event.ctrlKey : !event.ctrlKey || event.metaKey) return false
      return (
        !!document.activeElement?.matches('.editor-content[contenteditable="true"]') &&
        window.getSelection()?.isCollapsed === false
      )
    }
    const toggle = (event: KeyboardEvent) => {
      event.preventDefault()
      event.stopPropagation()
      if (commandOpen) setCommandOpen(false)
      else openCommand()
    }
    const shortcut = (event: KeyboardEvent) => {
      if (commandKey(event) && !linkKey(event)) toggle(event)
    }
    // The editor claims the link shortcut only where it can edit a link, such as outside code.
    const unclaimedLinkKey = (event: KeyboardEvent) => {
      if (commandKey(event) && !event.defaultPrevented) toggle(event)
    }
    window.addEventListener('keydown', shortcut, true)
    window.addEventListener('keydown', unclaimedLinkKey)
    return () => {
      window.removeEventListener('keydown', shortcut, true)
      window.removeEventListener('keydown', unclaimedLinkKey)
    }
  }, [commandOpen, openCommand])
  useEffect(() => {
    if (!composerLocationKey || commandOpen || focusedChatLocation.current === composerLocationKey) {
      return
    }
    const observer = new MutationObserver(focusComposer)
    function focusComposer() {
      if (document.querySelector('.pod-command-dialog:not([data-closed])')) return
      const composer = document.querySelector<HTMLTextAreaElement>(
        '.pod-chat-standalone .pod-chat-composer textarea:enabled'
      )
      if (!composer) return
      composer.focus()
      focusedChatLocation.current = composerLocationKey
      observer.disconnect()
      void navigate({ to: podLocation('/').pathname, replace: true, resetScroll: false })
    }
    focusComposer()
    if (focusedChatLocation.current !== composerLocationKey) {
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['disabled', 'data-open', 'data-closed']
      })
    }
    return () => observer.disconnect()
  }, [composerLocationKey, commandOpen, navigate])
  return (
    <PodCommandContext value={openCommand}>
      <TooltipProvider>
        <SidebarProvider
          className="pod-shell h-svh overflow-hidden"
          style={{ '--sidebar-width': `${sidebarLayout.width.value}px` } as CSSProperties}>
          <ErrorBoundary
            variant="panel"
            className="fixed bottom-3 left-3 z-50 w-(--sidebar-width) max-w-[calc(100vw-1.5rem)] md:static md:m-2 md:shrink-0 md:self-start"
            resetKeys={[pathname]}>
            <SlotGate slot={accountNavigation}>
              {enabled => (
                <PodSidebar
                  accountNavigation={enabled ? accountNavigation?.content : undefined}
                  layout={sidebarLayout}
                />
              )}
            </SlotGate>
          </ErrorBoundary>
          <SidebarInset className="min-h-0 overflow-hidden">
            <PodTopBar />
            <div className="min-h-0 flex-1 overflow-hidden has-data-sheet:overflow-visible">
              <Outlet />
            </div>
          </SidebarInset>
          <PodCommandMenu open={commandOpen} onOpenChange={setCommandOpen} returnFocus={commandReturnFocus} />
          {actionCardID && <StandaloneActionCardDialog cardID={actionCardID} onClose={closeActionCardDialog} />}
        </SidebarProvider>
      </TooltipProvider>
    </PodCommandContext>
  )
}

function PodTopBar({ pageFallback = false }: { pageFallback?: boolean } = {}) {
  const { t } = useTranslation()
  const { state } = useSidebar()
  const pathname = useLocation({ select: location => location.pathname })
  const isLoading = useRouterState({ select: routerState => routerState.isLoading })
  const contentHeader = pathname === '/' || pathname.startsWith('/pages/') || pathname.startsWith('/conversations/')
  if (contentHeader && !pageFallback) return null
  if (!contentHeader && pageFallback) return null

  return (
    <header className="flex h-11 shrink-0 items-center gap-2 px-3">
      <SidebarTrigger className={state === 'expanded' ? 'md:hidden' : undefined} label={t('pod.sidebar.expand')} />
      {isLoading && (
        <span role="status" className="text-xs text-fg-tertiary">
          {t('pod.content.loading')}
        </span>
      )}
    </header>
  )
}
