import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode
} from 'react'
import { SidebarInset, SidebarProvider, SidebarTrigger, TooltipProvider, useSidebar } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { createBrowserRouter, Outlet, useLocation, useNavigate, useNavigation, useRouteError } from 'react-router'
import { RouterProvider } from 'react-router/dom'
import { useQueryClient } from '@tanstack/react-query'
import { PodSidebar } from './sidebar'
import { ContentListRoute } from './page-navigation'
import { ContentProvider } from './content-context'
import { ContentError } from './content-primitives'
import { ChatDraftProvider } from './chat-drafts'
import { pageQuery } from './content-api'
import { podLocation, podRouteID } from '../common/browser-context'
import { PodCommandContext, PodCommandMenu, type PodCommandNavigationState } from './command-menu'
import './pod.css'

const AccountNavigation = createContext<ReactNode>(null)
const routeFeedback = { HydrateFallback: PodRouteLoading, ErrorBoundary: PodRouteError }
const loadChatRoute = async () => ({ Component: (await import('./chat-page')).ChatRoute })

/** `accountNavigation` adds `DropdownMenuItem`s to the sidebar account menu. */
type PodAppProps = { accountNavigation?: ReactNode }

export function PodApp({ accountNavigation }: PodAppProps = {}) {
  const client = useQueryClient()
  const router = useMemo(
    () =>
      createBrowserRouter([
        {
          element: <PodShell />,
          children: [
            { index: true, lazy: loadChatRoute, ...routeFeedback },
            {
              path: 'pages/:pageID',
              loader: async ({ params }) => {
                const pageID = podRouteID(params.pageID)
                if (!pageID) throw new Response('Page not found', { status: 404 })
                await client.prefetchQuery(pageQuery(pageID))
                return null
              },
              shouldRevalidate: ({ currentParams, nextParams }) => currentParams.pageID !== nextParams.pageID,
              lazy: async () => ({ Component: (await import('./page-workspace')).PageRoute }),
              ...routeFeedback
            },
            { path: 'content/:scope', element: <ContentListRoute /> },
            { path: 'conversations/:conversationID', lazy: loadChatRoute, ...routeFeedback }
          ]
        }
      ]),
    [client]
  )
  return (
    <AccountNavigation value={accountNavigation}>
      <ContentProvider>
        <ChatDraftProvider>
          <RouterProvider router={router} />
        </ChatDraftProvider>
      </ContentProvider>
    </AccountNavigation>
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

function PodRouteError() {
  const error = useRouteError()
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
  const accountNavigation = useContext(AccountNavigation)
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
  useEffect(() => {
    const state = location.state as PodCommandNavigationState | null
    if (
      location.pathname !== '/' ||
      !state?.focusComposer ||
      commandOpen ||
      focusedChatLocation.current === location.key
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
      focusedChatLocation.current = location.key
      observer.disconnect()
      void navigate(podLocation('/'), { replace: true, state: null, preventScrollReset: true })
    }
    focusComposer()
    if (focusedChatLocation.current !== location.key) {
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['disabled', 'data-open', 'data-closed']
      })
    }
    return () => observer.disconnect()
  }, [location.key, location.pathname, location.state, commandOpen, navigate])
  return (
    <PodCommandContext value={openCommand}>
      <TooltipProvider>
        <SidebarProvider
          className="pod-shell h-svh overflow-hidden"
          style={{ '--sidebar-width': '248px' } as CSSProperties}>
          <PodSidebar accountNavigation={accountNavigation} />
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
  const navigation = useNavigation()
  const contentHeader =
    location.pathname === '/' ||
    location.pathname.startsWith('/pages/') ||
    location.pathname.startsWith('/conversations/')
  if (contentHeader && !pageFallback) return null
  if (!contentHeader && pageFallback) return null
  if (!isMobile && state === 'expanded') {
    return navigation.state === 'loading' ? (
      <span role="status" className="absolute top-3 left-3 text-xs text-fg-tertiary">
        {t('pod.content.loading')}
      </span>
    ) : null
  }

  return (
    <header className="flex h-11 shrink-0 items-center gap-2 px-3">
      <SidebarTrigger label={t('pod.sidebar.expand')} />
      {navigation.state === 'loading' && (
        <span role="status" className="text-xs text-fg-tertiary">
          {t('pod.content.loading')}
        </span>
      )}
    </header>
  )
}
