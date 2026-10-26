import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
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
import { ContentListRoute } from './page-navigation'
import { ContentProvider } from './content-context'
import { ContentError } from './content-primitives'
import { ChatDraftProvider } from './chat-drafts'
import { pageQuery } from './content-api'
import { podLocation, podRouteID } from '../common/browser-context'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { PodCommandContext, PodCommandMenu, type PodCommandNavigationState } from './command-menu'
import './pod.css'

import { SlotGate, validateSlotIDs } from '../common/slots'
import { PodSlotsContext, usePodSlots, podSettingsSections, type PodAppSlots } from './slots'
export type { PodAppSlots } from './slots'
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
  const { accountNavigation } = usePodSlots()
  const location = useLocation()
  const navigate = useNavigate()
  const [commandOpen, setCommandOpen] = useState(false)
  const commandReturnFocus = useRef<HTMLElement | null>(null)
  const focusedChatLocation = useRef<string | null>(null)
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
  const { state, isMobile } = useSidebar()
  const location = useLocation()
  const isLoading = useRouterState({ select: routerState => routerState.isLoading })
  const contentHeader =
    location.pathname === '/' ||
    location.pathname.startsWith('/pages/') ||
    location.pathname.startsWith('/conversations/')
  if (contentHeader && !pageFallback) return null
  if (!contentHeader && pageFallback) return null
  if (!isMobile && state === 'expanded') {
    return isLoading ? (
      <span role="status" className="absolute top-3 left-3 text-xs text-fg-tertiary">
        {t('pod.content.loading')}
      </span>
    ) : null
  }

  return (
    <header className="flex h-11 shrink-0 items-center gap-2 px-3">
      <SidebarTrigger label={t('pod.sidebar.expand')} />
      {isLoading && (
        <span role="status" className="text-xs text-fg-tertiary">
          {t('pod.content.loading')}
        </span>
      )}
    </header>
  )
}
