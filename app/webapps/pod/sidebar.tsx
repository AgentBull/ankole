import { authenticationRef, podID } from '../common/browser-context'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarTrigger,
  useSidebar,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger
} from '@ankole/uikit'
import { RiChat3Line, RiHome5Line, RiSearchLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation } from '@tanstack/react-router'
import { ChatSidebar } from './chat/chat-sidebar'
import { AccountMenu } from './account-menu'
import { ContentNavigation, CreatePageButton } from './page-navigation'
import { contentKeys } from './content-api'
import { useQueryClient } from '@tanstack/react-query'
import { usePodCommandMenu } from './command-menu'

import { browserSession } from '../common/api/generated/sdk.gen'

export function PodSidebar({ accountNavigation }: { accountNavigation?: ReactNode }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const account = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
  const location = useLocation()
  const { isMobile, setOpenMobile } = useSidebar()
  const openCommand = usePodCommandMenu()
  const [tab, setTab] = useState<'home' | 'chat'>(
    location.pathname.includes('/pages/') || location.pathname.includes('/content/') ? 'home' : 'chat'
  )
  const closeMobile = () => {
    if (isMobile) setOpenMobile(false)
  }
  useEffect(() => {
    if (isMobile) setOpenMobile(false)
  }, [location.pathname, isMobile, setOpenMobile])
  useEffect(() => {
    setTab(location.pathname.includes('/pages/') || location.pathname.includes('/content/') ? 'home' : 'chat')
  }, [location.pathname])

  return (
    <Sidebar className="pod-sidebar" collapsible="offcanvas" mobileTitle={t('pod.sidebar.title')}>
      <SidebarHeader className="pod-sidebar-header">
        <div className="pod-sidebar-top">
          <button
            type="button"
            className="pod-search-slot"
            aria-keyshortcuts="Meta+K Control+K"
            onClick={() => {
              openCommand()
              closeMobile()
            }}>
            <RiSearchLine aria-hidden />
            <span className="truncate">{t('pod.command.open')}</span>
            <kbd aria-hidden>{navigator.platform.includes('Mac') ? '⌘K' : 'Ctrl K'}</kbd>
          </button>
          <CreatePageButton compact />
          <SidebarTrigger label={t('pod.sidebar.collapse')} />
        </div>
      </SidebarHeader>
      <Tabs
        value={tab}
        onValueChange={value => {
          setTab(value)
          if (value === 'home') void client.invalidateQueries({ queryKey: contentKeys.lists })
        }}
        className="min-h-0 flex-1 gap-0">
        <div className="px-2 pb-2">
          <TabsList
            className="pod-sidebar-tabs"
            activateOnFocus
            variant="object"
            aria-label={t('pod.sidebar.tabs_label')}>
            <TabsTrigger value="home">
              <RiHome5Line aria-hidden />
              {t('pod.sidebar.tabs.home')}
            </TabsTrigger>
            <TabsTrigger value="chat">
              <RiChat3Line aria-hidden />
              {t('pod.sidebar.tabs.chat')}
            </TabsTrigger>
          </TabsList>
        </div>
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
        {account.data?.canManagePod && (
          <Link to="/settings" className="p-2 text-sm">
            {t('pod.settings.title')}
          </Link>
        )}
        <AccountMenu extra={accountNavigation} />
      </SidebarFooter>
    </Sidebar>
  )
}

function ConversationMenu() {
  return <ChatSidebar />
}
