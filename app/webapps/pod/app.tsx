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
  useRouterState
} from '@tanstack/react-router'
import { useQueryClient } from '@tanstack/react-query'
import { PodSidebar } from './sidebar'
import { ContentListRoute } from './content-list'
import { ContentProvider } from './content-context'
import { ContentError } from './content-primitives'
import { ChatDraftProvider } from './chat-drafts'
import { podKeys, type ConversationDetail } from './api'
import { contentKeys, pageQuery, type PageDetail } from './content-api'
import { prefetchBase } from './base-api'
import { podLocation, podRouteID } from '../common/browser-context'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { PodCommandContext, PodCommandMenu, type PodCommandNavigationState } from './command-menu'
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
const routeFeedback = { pendingComponent: PodRouteLoading, pendingMs: 0, errorComponent: PodRouteError }
const LazyChatRoute = lazyRouteComponent(() => import('./chat-page'), 'ChatRoute')
const LazyPageRoute = lazyRouteComponent(() => import('./page-workspace'), 'PageRoute')

export function PodApp({ slots = {} }: { slots?: PodAppSlots } = {}) {
  validateSlotIDs(slots.settingsTabs ?? [], podSettingsSections)
  const client = useQueryClient()
  const router = useMemo(() => {
    const rootRoute = createRootRoute({ component: PodShell })
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
        component: LazyChatRoute,
        ...routeFeedback
      }),
      createRoute({
        getParentRoute: () => rootRoute,
        path: 'pages/$pageID',
        loader: async ({ params }) => {
          const pageID = podRouteID(params.pageID)
          if (!pageID) throw new Response('Page not found', { status: 404 })
          await client.prefetchQuery(pageQuery(pageID))
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
        component: ContentListRoute
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

function PodRouteError({ error }: { error: unknown }) {
  return (
    <>
      <PodTopBar pageFallback />
      <div className="p-8">
        <ContentError error={error} retry={() => window.location.reload()} />
      </div>
    </>
  )
}

function PodShell() {
  const { t } = useTranslation()
  const client = useQueryClient()
  const { accountNavigation } = usePodSlots()
  const location = useLocation()
  const navigate = useNavigate()
  const [commandOpen, setCommandOpen] = useState(false)
  const commandReturnFocus = useRef<HTMLElement | null>(null)
  const focusedChatLocation = useRef<string | null>(null)
  useLayoutEffect(() => {
    const conversationSegment = location.pathname.startsWith('/conversations/')
      ? decodeURIComponent(location.pathname.slice('/conversations/'.length).split('/')[0] ?? '')
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
      const next = podRouteTitle(location.pathname, t, conversationTitle)
      if (next) document.title = next
    }
    syncTitle()
    if (!conversationID) return
    return client.getQueryCache().subscribe(() => syncTitle())
  }, [client, location.pathname, t])
  const openCommand = useCallback(() => {
    commandReturnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setCommandOpen(true)
  }, [])
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (
        event.isComposing ||
        event.keyCode === 229 ||
        event.repeat ||
        event.altKey ||
        event.shiftKey ||
        !(event.metaKey || event.ctrlKey) ||
        event.key.toLowerCase() !== 'k'
      ) {
        return
      }
      event.preventDefault()
      event.stopPropagation()
      if (commandOpen) setCommandOpen(false)
      else openCommand()
    }
    window.addEventListener('keydown', shortcut, true)
    return () => window.removeEventListener('keydown', shortcut, true)
  }, [commandOpen, openCommand])
  const locationState = location.state as
    | (Partial<PodCommandNavigationState> & {
        __TSR_key?: string
        key?: string
      })
    | null
  const locationKey = locationState?.__TSR_key ?? locationState?.key ?? location.href
  useEffect(() => {
    if (
      location.pathname !== '/' ||
      !locationState?.focusComposer ||
      commandOpen ||
      focusedChatLocation.current === locationKey
    ) {
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
      focusedChatLocation.current = locationKey
      observer.disconnect()
      void navigate({ to: podLocation('/').pathname, replace: true, resetScroll: false })
    }
    focusComposer()
    if (focusedChatLocation.current !== locationKey) {
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['disabled', 'data-open', 'data-closed']
      })
    }
    return () => observer.disconnect()
  }, [locationKey, location.pathname, locationState?.focusComposer, commandOpen, navigate])
  return (
    <PodCommandContext value={openCommand}>
      <TooltipProvider>
        <SidebarProvider
          className="pod-shell h-svh overflow-hidden"
          style={{ '--sidebar-width': '248px' } as CSSProperties}>
          <SlotGate slot={accountNavigation}>
            {enabled => <PodSidebar accountNavigation={enabled ? accountNavigation?.content : undefined} />}
          </SlotGate>
          <SidebarInset className="min-h-0 overflow-hidden">
            <PodTopBar />
            <div className="min-h-0 flex-1 overflow-hidden">
              <Outlet />
            </div>
          </SidebarInset>
          <PodCommandMenu open={commandOpen} onOpenChange={setCommandOpen} returnFocus={commandReturnFocus} />
        </SidebarProvider>
      </TooltipProvider>
    </PodCommandContext>
  )
}

function PodTopBar({ pageFallback = false }: { pageFallback?: boolean } = {}) {
  const { t } = useTranslation()
  const { state } = useSidebar()
  const location = useLocation()
  const isLoading = useRouterState({ select: routerState => routerState.isLoading })
  const contentHeader =
    location.pathname === '/' ||
    location.pathname.startsWith('/pages/') ||
    location.pathname.startsWith('/conversations/')
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
