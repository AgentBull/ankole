import { authenticationRef, podID, podLocation } from '../common/browser-context'
import {
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
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation } from '@tanstack/react-router'
import { ChatSidebar } from './chat/chat-sidebar'
import { AccountMenu } from './account-menu'
import { ContentNavigation } from './page-navigation'
import { CreatePageButton } from './page-create-menu'
import { podKeys } from './api'
import { contentKeys } from './content-api'
import { usePodCommandMenu } from './command-menu'

import { browserSession } from '../common/api/generated/sdk.gen'

export type PodSidebarNavigationState = { keepSidebarTab?: 'home' | 'chat' }

export function routeSidebarTab(
  pathname: string,
  state?: PodSidebarNavigationState | null
): 'home' | 'chat' | undefined {
  if (state?.keepSidebarTab) return state.keepSidebarTab
  if (pathname.startsWith('/pages/') || pathname.startsWith('/content/')) return 'home'
  if (pathname === '/' || pathname.startsWith('/conversations/')) return 'chat'
  return undefined
}

export function PodSidebar({ accountNavigation }: { accountNavigation?: ReactNode }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const account = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
  const location = useLocation()
  const navState = location.state as PodSidebarNavigationState | null
  const { isMobile, setOpenMobile } = useSidebar()
  const openCommand = usePodCommandMenu()
  const [tab, setTab] = useState<'home' | 'chat'>(() => routeSidebarTab(location.pathname, navState) ?? 'chat')
  const settingsActive = location.pathname === '/settings' || location.pathname.startsWith('/settings/')
  const trashPath = podLocation('/content/trash').pathname
  const trashActive = location.pathname === trashPath
  const shortcut = typeof navigator !== 'undefined' && navigator.platform.includes('Mac') ? '⌘K' : 'Ctrl+K'
  const closeMobile = () => {
    if (isMobile) setOpenMobile(false)
  }
  useEffect(() => {
    if (isMobile) setOpenMobile(false)
  }, [location.pathname, isMobile, setOpenMobile])
  useEffect(() => {
    const next = routeSidebarTab(location.pathname, navState)
    if (next) setTab(next)
  }, [location.pathname, navState?.keepSidebarTab])

  return (
    <Sidebar className="pod-sidebar" variant="inset" collapsible="offcanvas" mobileTitle={t('pod.sidebar.title')}>
      <Tabs
        value={tab}
        onValueChange={value => {
          setTab(value)
          if (value === 'home') {
            void client.invalidateQueries({ queryKey: contentKeys.lists })
            void client.invalidateQueries({ queryKey: podKeys.conversations })
          }
        }}
        className="min-h-0 flex-1 gap-0">
        <SidebarHeader className="pod-sidebar-header">
          <div className="pod-sidebar-top">
            <TabsList
              className="pod-sidebar-tabs"
              activateOnFocus
              variant="object"
              aria-label={t('pod.sidebar.tabs_label')}>
              <TabsTrigger value="home">
                <RiHome5Line aria-hidden />
                <span>{t('pod.sidebar.tabs.home')}</span>
              </TabsTrigger>
              <TabsTrigger value="chat">
                <RiChat3Line aria-hidden />
                <span>{t('pod.sidebar.tabs.chat')}</span>
              </TabsTrigger>
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
              {tab === 'home' ? (
                <CreatePageButton compact />
              ) : (
                <Tooltip>
                  <TooltipTrigger
                    render={
                      <Link
                        to={podLocation('/').pathname}
                        onClick={closeMobile}
                        className={buttonVariants({ variant: 'ghost', size: 'icon-sm' })}
                        aria-label={t('pod.chat.new_conversation')}
                        title={t('pod.chat.new_conversation')}
                      />
                    }>
                    <RiAddLine aria-hidden />
                  </TooltipTrigger>
                  <TooltipContent>{t('pod.chat.new_conversation')}</TooltipContent>
                </Tooltip>
              )}
              <SidebarTrigger label={t('pod.sidebar.collapse')} />
            </div>
          </div>
        </SidebarHeader>
        <SidebarContent>
          <TabsContent value="home" className="px-2 pb-3 text-[13px] leading-5">
            <ContentNavigation onNavigate={closeMobile} />
          </TabsContent>
          <TabsContent value="chat" className="pod-conversations px-2 pb-3 text-[13px] leading-5">
            <ConversationMenu />
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
  )
}

function ConversationMenu() {
  return <ChatSidebar />
}
