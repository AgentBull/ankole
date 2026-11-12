import { isApplePlatform } from '../common/platform'
import { commentAttentionQuery } from './content-api'
import { useChatDrafts } from './chat-drafts'
import { podLocation } from '../common/browser-context'
import {
  Badge,
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarHeaderRow,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuIcon,
  SidebarMenuItem,
  SidebarSeparator,
  SidebarTrigger,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  useSidebar,
  Tabs,
  TabsContent,
  TabsLabel,
  TabsList,
  TabsTrigger
} from '@ankole/uikit'
import { AddRegular, ChatRegular, HomeRegular } from '@ankole/uikit/icons'
import { useQuery } from '@tanstack/react-query'
import {
  Activity,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import { useSignals } from '@preact/signals-react/runtime'
import { useLocation, useNavigate } from '@tanstack/react-router'
import { ErrorBoundary } from '../common/error-boundary'
import { ChatSidebar } from './chat/chat-sidebar'
import { AccountMenu } from './account-menu'
import { ContentNavigation, SidebarLink } from './page-navigation'
import type { PodSidebarNavigationState } from './state/navigation'
import { POD_SIDEBAR_MAX_WIDTH, POD_SIDEBAR_MIN_WIDTH, SidebarLayoutModel } from './state/sidebar-layout'

import { agentsQuery, conversationAttentionQuery } from './api'

export type PodSidebarTab = 'home' | 'chat'

export function routeSidebarTab(pathname: string, state?: PodSidebarNavigationState | null): PodSidebarTab | undefined {
  if (state?.keepSidebarTab) return state.keepSidebarTab
  if (
    pathname === '/work' ||
    pathname === '/meta' ||
    pathname.startsWith('/meta/') ||
    pathname.startsWith('/pages/') ||
    pathname.startsWith('/content/')
  ) {
    return 'home'
  }
  if (pathname === '/' || pathname.startsWith('/dm/') || pathname.startsWith('/conversations/')) return 'chat'
  return undefined
}

export function PodSidebar({
  accountNavigation,
  layout
}: {
  accountNavigation?: ReactNode
  layout: InstanceType<typeof SidebarLayoutModel>
}) {
  const { t } = useTranslation()
  const drafts = useChatDrafts()
  const agents = useQuery(agentsQuery)
  const rooms = useQuery(conversationAttentionQuery)
  const chatAttention =
    rooms.data?.filter(
      room =>
        room.rowStatus === 'waiting_choice' ||
        (room.conversationKind !== 'assistant_task' && room.rowStatus === 'unread')
    ).length ?? 0
  const commentAttention = useQuery(commentAttentionQuery)
  const homeAttention = commentAttention.data?.length ?? 0
  const navigate = useNavigate()
  const pathname = useLocation({ select: location => location.pathname })
  const routeTab = useLocation({
    select: location => routeSidebarTab(location.pathname, location.state as PodSidebarNavigationState | null)
  })
  const { isMobile, state, setOpenMobile } = useSidebar()
  const [tab, setTab] = useState<PodSidebarTab>(() => routeTab ?? 'chat')
  // New Chat sits above both tabs, so it opens the composer without switching away from the open tab.
  useEffect(() => {
    if (!agents.data?.personalAssistantAvailable) return
    const newChat = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.shiftKey && !event.altKey && event.key.toLowerCase() === 'o') {
        event.preventDefault()
        drafts.startNew()
        void navigate({ to: podLocation('/').pathname, state: { keepSidebarTab: tab } as never })
      }
    }
    window.addEventListener('keydown', newChat)
    return () => window.removeEventListener('keydown', newChat)
  }, [agents.data?.personalAssistantAvailable, navigate, drafts, tab])
  const [previewOpen, setPreviewOpen] = useState(false)
  const mac = isApplePlatform()
  const preview = previewOpen && state === 'collapsed' && !isMobile
  // The preview's panel outlives the preview by one motion: it fades out where it stands when the pointer leaves, and
  // it keeps its surface above the card while the card makes room for the docked column.
  const [panel, setPanel] = useState<'preview' | 'leaving' | 'docking' | null>(null)
  if (preview && panel !== 'preview') setPanel('preview')
  else if (!preview && panel === 'preview') setPanel(isMobile ? null : state === 'expanded' ? 'docking' : 'leaving')
  else if (
    (panel === 'leaving' && (state === 'expanded' || isMobile)) ||
    (panel === 'docking' && (state === 'collapsed' || isMobile))
  ) {
    setPanel(null)
  }
  useEffect(() => {
    if (panel !== 'leaving' && panel !== 'docking') return
    const timer = setTimeout(
      () => setPanel(null),
      motionDuration(panel === 'leaving' ? '--duration-feedback' : '--duration-drawer')
    )
    return () => clearTimeout(timer)
  }, [panel])
  const closeMobile = () => {
    if (isMobile) setOpenMobile(false)
  }
  const leavePreview = (event: ReactPointerEvent<HTMLElement>) => {
    const next = event.relatedTarget
    if (next instanceof Element && next.closest('[data-pod-sidebar-hover]')) return
    setPreviewOpen(false)
  }
  useEffect(() => {
    if (isMobile) setOpenMobile(false)
  }, [pathname, isMobile, setOpenMobile])
  useEffect(() => {
    if (routeTab) setTab(routeTab)
  }, [pathname, routeTab])
  useEffect(() => {
    if (state === 'expanded' || isMobile) setPreviewOpen(false)
  }, [state, isMobile])

  return (
    <>
      <Sidebar
        className={panel ? 'pod-sidebar pod-sidebar-preview ceramic' : 'pod-sidebar'}
        data-preview={panel === 'leaving' || panel === 'docking' ? panel : undefined}
        variant="inset"
        collapsible="offcanvas"
        mobileTitle={t('pod.sidebar.title')}
        // A collapsed sidebar stays out of the tab order, except while the pointer previews it.
        inert={preview ? false : undefined}
        data-pod-sidebar-hover
        onPointerEnter={() => {
          if (state === 'collapsed') setPreviewOpen(true)
        }}
        onPointerLeave={leavePreview}>
        <Tabs value={tab} onValueChange={setTab} className="min-h-0 flex-1 gap-0">
          <SidebarHeader className="pod-sidebar-header">
            <SidebarHeaderRow className="pod-sidebar-top">
              <TabsList
                className="pod-sidebar-tabs"
                activateOnFocus
                variant="chip"
                aria-label={t('pod.sidebar.tabs_label')}>
                {(
                  [
                    ['home', HomeRegular, t('pod.sidebar.tabs.home')],
                    ['chat', ChatRegular, t('pod.sidebar.tabs.chat')]
                  ] as const
                ).map(([value, Icon, label]) => (
                  // Only the open tab shows its label, so a closed tab names itself in a tooltip.
                  <Tooltip key={value} disabled={tab === value}>
                    <TooltipTrigger
                      render={
                        <TabsTrigger
                          value={value}
                          aria-label={label}
                          aria-description={
                            value === 'chat' && chatAttention > 0
                              ? t('pod.superagent.attention', { count: chatAttention })
                              : value === 'home' && homeAttention > 0
                                ? t('pod.document.unread_comments')
                                : undefined
                          }
                        />
                      }>
                      <Icon aria-hidden />
                      {/* The label opens and closes with the selection; the tab's accessible name comes from aria-label. */}
                      <TabsLabel aria-hidden>{label}</TabsLabel>
                      {/* Both tabs announce work that waits for the viewer with the same badge. */}
                      {(value === 'chat' ? chatAttention : homeAttention) > 0 && (
                        <Badge variant="info" size="sm" aria-hidden>
                          {value === 'chat' ? chatAttention : homeAttention}
                        </Badge>
                      )}
                    </TooltipTrigger>
                    <TooltipContent>{label}</TooltipContent>
                  </Tooltip>
                ))}
              </TabsList>
              {/* On a phone the sidebar is a sheet, and the toggle closes it; a hover preview pins the sidebar open. */}
              <SidebarTrigger
                label={state === 'expanded' || isMobile ? t('pod.sidebar.collapse') : t('pod.sidebar.expand')}
              />
            </SidebarHeaderRow>
            <SidebarSeparator />
            {agents.data?.personalAssistantAvailable && (
              <SidebarMenu>
                <SidebarMenuItem>
                  {/* Starting a conversation is an action, so the row never takes the current mark of the chat home. */}
                  <SidebarMenuButton
                    render={
                      <SidebarLink
                        to={podLocation('/').pathname}
                        state={{ keepSidebarTab: tab } as never}
                        current={false}
                        activeProps={{}}
                        onClick={() => {
                          drafts.startNew()
                          closeMobile()
                        }}
                        aria-keyshortcuts="Meta+Shift+O Control+Shift+O"
                      />
                    }
                    className="pod-nav-link">
                    <SidebarMenuIcon tone="secondary">
                      <AddRegular />
                    </SidebarMenuIcon>
                    <span className="min-w-0 flex-1 truncate">{t('pod.chat.new_conversation')}</span>
                    <span
                      aria-hidden
                      className="shrink-0 text-50 text-fg-tertiary opacity-0 transition-opacity duration-(--duration-feedback) group-hover/menu-button:opacity-100 group-focus-visible/menu-button:opacity-100 [@media(hover:none)]:hidden">
                      {mac ? '⌘⇧O' : 'Ctrl+Shift+O'}
                    </span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            )}
          </SidebarHeader>
          <SidebarContent>
            <TabsContent value="home" keepMounted className="pb-3">
              <Activity mode={tab === 'home' ? 'visible' : 'hidden'}>
                <ErrorBoundary variant="inline" resetKeys={[pathname]}>
                  <ContentNavigation onNavigate={closeMobile} />
                </ErrorBoundary>
              </Activity>
            </TabsContent>
            <TabsContent value="chat" className="px-2 pt-2 pb-3">
              <ErrorBoundary variant="inline" resetKeys={[pathname]}>
                <ConversationMenu />
              </ErrorBoundary>
            </TabsContent>
          </SidebarContent>
        </Tabs>
        <SidebarFooter>
          <AccountMenu extra={accountNavigation} />
        </SidebarFooter>
      </Sidebar>
      <SidebarResizeHandle layout={layout} />
      {!isMobile && state === 'collapsed' && (
        <div
          aria-hidden
          data-pod-sidebar-hover
          className="pod-sidebar-hover-rail"
          onPointerEnter={() => setPreviewOpen(true)}
          onPointerLeave={leavePreview}
        />
      )}
    </>
  )
}

function SidebarResizeHandle({ layout }: { layout: InstanceType<typeof SidebarLayoutModel> }) {
  useSignals()
  const { t } = useTranslation()
  const { isMobile, state } = useSidebar()
  const drag = useRef<{ pointerId: number; startX: number; startWidth: number } | null>(null)
  const width = layout.width.value

  useEffect(
    () => () => {
      if (drag.current) layout.commitWidth(layout.width.peek())
    },
    [layout]
  )

  if (isMobile || state !== 'expanded') return null

  const finishResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (drag.current?.pointerId !== event.pointerId) return
    drag.current = null
    layout.commitWidth(layout.width.peek())
    delete event.currentTarget.dataset.resizing
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }
  const resizeWithKeyboard = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    let next: number
    switch (event.key) {
      case 'ArrowLeft':
        next = layout.width.peek() - 16
        break
      case 'ArrowRight':
        next = layout.width.peek() + 16
        break
      case 'Home':
        next = POD_SIDEBAR_MIN_WIDTH
        break
      case 'End':
        next = POD_SIDEBAR_MAX_WIDTH
        break
      default:
        return
    }
    event.preventDefault()
    layout.commitWidth(next)
  }

  return (
    <div
      role="separator"
      aria-label={t('pod.sidebar.resize')}
      aria-orientation="vertical"
      aria-valuemin={POD_SIDEBAR_MIN_WIDTH}
      aria-valuemax={POD_SIDEBAR_MAX_WIDTH}
      aria-valuenow={width}
      tabIndex={0}
      className="pod-sidebar-resize-handle resize-edge"
      onKeyDown={resizeWithKeyboard}
      onPointerDown={event => {
        if (event.button !== 0) return
        event.preventDefault()
        event.currentTarget.focus({ preventScroll: true })
        event.currentTarget.setPointerCapture(event.pointerId)
        event.currentTarget.dataset.resizing = ''
        drag.current = { pointerId: event.pointerId, startX: event.clientX, startWidth: layout.width.peek() }
      }}
      onPointerMove={event => {
        const current = drag.current
        if (current?.pointerId !== event.pointerId) return
        layout.previewWidth(current.startWidth + event.clientX - current.startX)
      }}
      onPointerUp={finishResize}
      onPointerCancel={finishResize}
      onLostPointerCapture={finishResize}
    />
  )
}

function ConversationMenu() {
  return <ChatSidebar />
}

/** The length of a motion token in milliseconds, or 0 while the screen asks for reduced motion. */
function motionDuration(token: string) {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return 0
  return Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue(token)) || 0
}
