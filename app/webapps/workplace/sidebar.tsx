import {
  Button,
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuItem,
  SidebarMenuButton,
  SidebarTrigger,
  useSidebar,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  Tooltip,
  TooltipContent,
  TooltipTrigger
} from '@ankole/uikit'
import { RiAddLine, RiChat3Line, RiHome5Line, RiLogoutBoxRLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation } from 'react-router'
import { endSiteSession } from '../common/browser-session'
import { ThemeToggle } from '../common/theme-toggle'
import { conversationsQuery } from './api'

export function WorkplaceSidebar() {
  const { t } = useTranslation()
  const [tab, setTab] = useState<'home' | 'chat'>('chat')

  // `Sidebar` must be a direct child of `SidebarProvider`: `SidebarInset`
  // reads the sidebar state through `peer-data-*` selectors.
  return (
    <Sidebar variant="inset" collapsible="offcanvas" mobileTitle={t('workplace.sidebar.title')}>
      <Tabs value={tab} onValueChange={setTab} className="min-h-0 flex-1 gap-0">
        <SidebarHeader className="h-11 flex-row items-center gap-1 p-0">
          <TabsList activateOnFocus variant="object" aria-label={t('workplace.sidebar.tabs_label')}>
            <TabsTrigger value="home">
              <RiHome5Line aria-hidden />
              {t('workplace.sidebar.tabs.home')}
            </TabsTrigger>
            <TabsTrigger value="chat">
              <RiChat3Line aria-hidden />
              {t('workplace.sidebar.tabs.chat')}
            </TabsTrigger>
          </TabsList>
          <SidebarTrigger className="ml-auto" label={t('workplace.sidebar.collapse')} />
        </SidebarHeader>
        <SidebarContent>
          <TabsContent value="home" className="px-2 pt-3 text-[13px] leading-5 text-fg-tertiary">
            {t('workplace.sidebar.home_empty')}
          </TabsContent>
          <TabsContent value="chat" className="px-2 pt-3 text-[13px] leading-5 text-fg-tertiary">
            <ConversationMenu />
          </TabsContent>
        </SidebarContent>
      </Tabs>
      <SidebarFooter className="h-11 flex-row items-center gap-1 border-t border-sidebar-border p-0 pl-2">
        <span
          aria-hidden
          className="grid size-6 shrink-0 place-items-center rounded-[6px] bg-primary text-xs font-semibold text-primary-foreground">
          A
        </span>
        <span className="min-w-0 flex-1 truncate text-[13px] font-semibold">Ankole</span>
        <ThemeToggle />
        <SignOutButton />
      </SidebarFooter>
    </Sidebar>
  )
}

function ConversationMenu() {
  const { t } = useTranslation()
  const location = useLocation()
  const { isMobile, setOpenMobile } = useSidebar()
  const conversations = useQuery(conversationsQuery)
  const close = () => {
    if (isMobile) setOpenMobile(false)
  }
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <SidebarMenuButton render={<Link to="/" />} isActive={location.pathname === '/'} onClick={close}>
          <RiAddLine aria-hidden />
          <span>{t('workplace.chat.new_conversation')}</span>
        </SidebarMenuButton>
      </SidebarMenuItem>
      {conversations.isPending ? (
        <li role="status" className="px-3 py-2">
          {t('workplace.chat.loading_history')}
        </li>
      ) : null}
      {conversations.isError ? (
        <li className="space-y-2 px-3 py-2">
          <p role="alert">{t('workplace.chat.history_failed')}</p>
          <Button size="xs" variant="outline" onClick={() => void conversations.refetch()}>
            {t('workplace.chat.retry_load')}
          </Button>
        </li>
      ) : null}
      {!conversations.isPending && !conversations.isError && !conversations.data?.conversations.length ? (
        <li className="px-3 py-2">{t('workplace.sidebar.chat_empty')}</li>
      ) : null}
      {conversations.data?.conversations.map(conversation => (
        <SidebarMenuItem key={conversation.id}>
          <SidebarMenuButton
            render={<Link to={`/conversations/${conversation.id}`} />}
            isActive={location.pathname === `/conversations/${conversation.id}`}
            onClick={close}
            title={conversation.title}>
            <span>{conversation.title}</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
      ))}
    </SidebarMenu>
  )
}

function SignOutButton() {
  const { t } = useTranslation()
  const label = t('workplace.sidebar.sign_out')
  const signOut = useMutation({
    mutationFn: endSiteSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <Tooltip>
      <TooltipTrigger
        render={<Button aria-label={label} disabled={signOut.isPending} size="icon-sm" type="button" variant="ghost" />}
        onClick={() => signOut.mutate()}>
        <RiLogoutBoxRLine aria-hidden />
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}
