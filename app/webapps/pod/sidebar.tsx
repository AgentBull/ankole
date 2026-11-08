import { isApplePlatform } from '../common/platform'
import { commentAttentionQuery } from './content-api'
import { useChatDrafts } from './chat-drafts'
import { authenticationRef, podID, podLocation } from '../common/browser-context'
import {
  Badge,
  Button,
  buttonVariants,
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarTrigger,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
  useSidebar,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@ankole/uikit'
import { RiAddLine, RiChat3Line, RiDeleteBinLine, RiHome5Line, RiSearchLine, RiSettings3Line } from '@remixicon/react'
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
import { Link, useLocation, useNavigate } from '@tanstack/react-router'
import { ErrorBoundary } from '../common/error-boundary'
import { ChatSidebar } from './chat/chat-sidebar'
import { AccountMenu } from './account-menu'
import { ContentNavigation } from './page-navigation'
import { CreatePageButton } from './page-create-menu'
import { usePodCommandMenu } from './command-menu'
import type { PodSidebarNavigationState } from './state/navigation'
import { POD_SIDEBAR_MAX_WIDTH, POD_SIDEBAR_MIN_WIDTH, SidebarLayoutModel } from './state/sidebar-layout'

import { agentsQuery, conversationAttentionQuery } from './api'
import { browserSession } from '../common/api/generated/sdk.gen'

export function routeSidebarTab(
  pathname: string,
  state?: PodSidebarNavigationState | null
): 'home' | 'chat' | undefined {
  if (state?.keepSidebarTab) return state.keepSidebarTab
  if (
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
  const account = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
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
  const openCommand = usePodCommandMenu()
  const [tab, setTab] = useState<'home' | 'chat'>(() => routeTab ?? 'chat')
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
  const settingsActive = pathname === '/settings' || pathname.startsWith('/settings/')
  const trashPath = podLocation('/content/trash').pathname
  const trashActive = pathname === trashPath
  const mac = isApplePlatform()
  const shortcut = mac ? '⌘K' : 'Ctrl+K'
  const preview = previewOpen && state === 'collapsed' && !isMobile
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
        className={preview ? 'pod-sidebar pod-sidebar-preview ceramic' : 'pod-sidebar'}
        variant="inset"
        collapsible="offcanvas"
        mobileTitle={t('pod.sidebar.title')}
        data-pod-sidebar-hover
        onPointerEnter={() => {
          if (state === 'collapsed') setPreviewOpen(true)
        }}
        onPointerLeave={leavePreview}>
        <Tabs value={tab} onValueChange={setTab} className="min-h-0 flex-1 gap-0">
          <SidebarHeader className="pod-sidebar-header">
            <div className="pod-sidebar-top">
              <TabsList
                className="pod-sidebar-tabs"
                activateOnFocus
                variant="object"
                aria-label={t('pod.sidebar.tabs_label')}>
                {(
                  [
                    ['home', RiHome5Line, t('pod.sidebar.tabs.home')],
                    ['chat', RiChat3Line, t('pod.sidebar.tabs.chat')]
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
                      <span className={tab === value ? undefined : 'sr-only'}>{label}</span>
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
              <div className="pod-sidebar-top-actions">
                <Tooltip>
                  <TooltipTrigger
                    render={
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        aria-label={t('pod.command.open')}
                        aria-keyshortcuts="Meta+K Control+K"
                        onClick={() => {
                          openCommand()
                          closeMobile()
                        }}
                      />
                    }>
                    <RiSearchLine aria-hidden />
                  </TooltipTrigger>
                  <TooltipContent>{`${t('pod.command.open')} (${shortcut})`}</TooltipContent>
                </Tooltip>
                {tab === 'home' && <CreatePageButton compact />}
                <SidebarTrigger label={t('pod.sidebar.collapse')} />
              </div>
            </div>
            {agents.data?.personalAssistantAvailable && (
              <Link
                to={podLocation('/').pathname}
                state={{ keepSidebarTab: tab } as never}
                onClick={() => {
                  drafts.startNew()
                  closeMobile()
                }}
                className="nav-row pod-nav-link pod-new-chat"
                aria-keyshortcuts="Meta+Shift+O Control+Shift+O">
                <RiAddLine aria-hidden />
                <span className="min-w-0 flex-1 truncate">{t('pod.chat.new_conversation')}</span>
                <span className="pod-new-chat-shortcut" aria-hidden>
                  {mac ? '⌘⇧O' : 'Ctrl+Shift+O'}
                </span>
              </Link>
            )}
          </SidebarHeader>
          <SidebarContent>
            <TabsContent value="home" keepMounted className="px-2 pb-3 text-[13px] leading-5">
              <Activity mode={tab === 'home' ? 'visible' : 'hidden'}>
                <ErrorBoundary variant="inline" resetKeys={[pathname]}>
                  <ContentNavigation onNavigate={closeMobile} />
                </ErrorBoundary>
              </Activity>
            </TabsContent>
            <TabsContent value="chat" className="pod-conversations px-2 pb-3 text-[13px] leading-5">
              <ErrorBoundary variant="inline" resetKeys={[pathname]}>
                <ConversationMenu />
              </ErrorBoundary>
            </TabsContent>
          </SidebarContent>
        </Tabs>
        <SidebarFooter className="pod-sidebar-footer">
          <div className="min-w-0 flex-1">
            <AccountMenu extra={accountNavigation} />
          </div>
          <div className="flex shrink-0 items-center gap-0.5">
            <Tooltip>
              <TooltipTrigger
                render={
                  <Link
                    to={trashPath}
                    aria-current={trashActive ? 'page' : undefined}
                    onClick={closeMobile}
                    className={buttonVariants({ variant: 'ghost', size: 'icon-sm', className: 'pod-footer-action' })}
                    data-active={trashActive ? '' : undefined}
                    aria-label={t('pod.content.trash')}
                  />
                }>
                <RiDeleteBinLine aria-hidden />
              </TooltipTrigger>
              <TooltipContent>{t('pod.content.trash')}</TooltipContent>
            </Tooltip>
            {account.data?.canManagePod && (
              <Tooltip>
                <TooltipTrigger
                  render={
                    <Link
                      to={podLocation('/settings').pathname}
                      aria-current={settingsActive ? 'page' : undefined}
                      onClick={closeMobile}
                      className={buttonVariants({ variant: 'ghost', size: 'icon-sm', className: 'pod-footer-action' })}
                      data-active={settingsActive ? '' : undefined}
                      aria-label={t('pod.settings.title')}
                    />
                  }>
                  <RiSettings3Line aria-hidden />
                </TooltipTrigger>
                <TooltipContent>{t('pod.settings.title')}</TooltipContent>
              </Tooltip>
            )}
          </div>
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
      className="pod-sidebar-resize-handle"
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
