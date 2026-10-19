import { podID, podLocation } from '../common/browser-context'
import {
  Button,
  buttonVariants,
  Dialog,
  DialogContent,
  DialogTitle,
  DialogFooter,
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
  TooltipTrigger,
  toast
} from '@ankole/uikit'
import { RiAddLine, RiChat3Line, RiDeleteBinLine, RiHome5Line, RiLogoutBoxRLine, RiSearchLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate } from 'react-router'
import { endPodSession } from '../common/browser-session'
import { ThemeToggle } from '../common/theme-toggle'
import { conversationsQuery } from './api'
import { ContentNavigation, CreatePageButton } from './page-navigation'
import { contentError } from './content-errors'
import { requestErrorMessage } from '../common/request-errors'
import { contentKeys } from './content-api'
import { deleteConversation } from '../common/api/generated/sdk.gen'
import { podKeys } from './api'
import { useQueryClient } from '@tanstack/react-query'
import { usePodCommandMenu } from './command-menu'

export function PodSidebar({ accountNavigation }: { accountNavigation?: ReactNode }) {
  const { t } = useTranslation()
  const client = useQueryClient()
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
      <SidebarHeader className="gap-1 px-2 pt-2 pb-1">
        <div className="pod-workspace-row">
          <Link className="pod-workspace-link" to={podLocation('/content/space')} onClick={closeMobile}>
            <span aria-hidden className="pod-workspace-mark">
              A
            </span>
            <span className="truncate">Ankole</span>
          </Link>
          <CreatePageButton compact />
          <SidebarTrigger label={t('pod.sidebar.collapse')} />
        </div>
        <button
          type="button"
          className="pod-nav-link w-full cursor-pointer text-left"
          aria-keyshortcuts="Meta+K Control+K"
          onClick={() => {
            openCommand()
            closeMobile()
          }}>
          <RiSearchLine aria-hidden />
          <span>{t('pod.command.open')}</span>
          <kbd aria-hidden className="ml-auto text-[10px] text-fg-tertiary">
            {navigator.platform.includes('Mac') ? '⌘ K' : 'Ctrl K'}
          </kbd>
        </button>
      </SidebarHeader>
      <Tabs
        value={tab}
        onValueChange={value => {
          setTab(value)
          if (value === 'home') void client.invalidateQueries({ queryKey: contentKeys.lists })
        }}
        className="min-h-0 flex-1 gap-0">
        <div className="px-2 pb-1">
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
          <TabsContent value="home" className="px-2 pt-1 text-[13px] leading-5">
            <ContentNavigation onNavigate={closeMobile} />
          </TabsContent>
          <TabsContent value="chat" className="pod-conversations px-2 pt-1 text-[13px] leading-5">
            <ConversationMenu />
          </TabsContent>
        </SidebarContent>
      </Tabs>
      <SidebarFooter className="flex-row items-center gap-1 px-3 py-2">
        <div className="min-w-0 flex-1">
          {accountNavigation ?? (
            <a
              className={buttonVariants({ size: 'xs', variant: 'ghost' })}
              href={`/sessions/new?switch=1&return_to=${encodeURIComponent(location.pathname + location.search + location.hash)}`}>
              {t('common.switch_account')}
            </a>
          )}
        </div>
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
  const client = useQueryClient(),
    navigate = useNavigate()
  const [deleting, setDeleting] = useState<{ id: string; title: string }>()
  const remove = useMutation({
    mutationFn: (id: string) => deleteConversation({ path: { id } }),
    onError: error => toast.error(requestErrorMessage(contentError(error))),
    onSuccess: async (_result, id) => {
      await client.invalidateQueries({ queryKey: podKeys.conversations })
      setDeleting(undefined)
      if (location.pathname === podLocation(`/conversations/${id}`).pathname) navigate(podLocation('/'))
    }
  })
  const close = () => {
    if (isMobile) setOpenMobile(false)
  }
  return (
    <>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton
            render={<Link to={podLocation('/')} />}
            isActive={location.pathname === '/'}
            onClick={close}>
            <RiAddLine aria-hidden />
            <span>{t('pod.chat.new_conversation')}</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
        {conversations.isPending ? (
          <li role="status" className="px-3 py-2">
            {t('pod.chat.loading_history')}
          </li>
        ) : null}
        {conversations.isError ? (
          <li className="space-y-2 px-3 py-2">
            <p role="alert">{t('pod.chat.history_failed')}</p>
            <Button size="xs" variant="outline" onClick={() => void conversations.refetch()}>
              {t('pod.chat.retry_load')}
            </Button>
          </li>
        ) : null}
        {!conversations.isPending && !conversations.isError && !conversations.data?.conversations.length ? (
          <li className="px-3 py-2">{t('pod.sidebar.chat_empty')}</li>
        ) : null}
        {conversations.data?.conversations.map(conversation => (
          <SidebarMenuItem key={conversation.id} className="pod-chat-row flex items-center">
            <SidebarMenuButton
              render={<Link to={podLocation(`/conversations/${conversation.id}`)} />}
              isActive={location.pathname === podLocation(`/conversations/${conversation.id}`).pathname}
              onClick={close}
              title={conversation.title}>
              <RiChat3Line aria-hidden className="text-fg-tertiary" />
              <span>{conversation.title}</span>
            </SidebarMenuButton>
            <Button
              variant="ghost"
              size="icon-sm"
              className="pod-row-action"
              aria-label={t('pod.content.delete_conversation', { value1: conversation.title })}
              disabled={remove.isPending}
              onClick={() => {
                remove.reset()
                setDeleting(conversation)
              }}>
              <RiDeleteBinLine aria-hidden className="size-4" />
            </Button>
          </SidebarMenuItem>
        ))}
      </SidebarMenu>
      <Dialog
        open={!!deleting}
        onOpenChange={open => {
          if (!open && !remove.isPending) setDeleting(undefined)
        }}>
        <DialogContent className="pod-dialog" closeLabel={t('common.close')} showCloseButton={!remove.isPending}>
          <DialogTitle>{t('pod.content.delete_conversation_2')}</DialogTitle>
          <p className="text-sm">
            {t('pod.content.deleting_cannot_be_undone_pages_saved_to_pod_will_be', { title: deleting?.title ?? '' })}
          </p>
          {remove.error && <p role="alert">{requestErrorMessage(contentError(remove.error))}</p>}
          <DialogFooter>
            <Button variant="outline" disabled={remove.isPending} onClick={() => setDeleting(undefined)}>
              {t('pod.content.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={remove.isPending}
              onClick={() => deleting && remove.mutate(deleting.id)}>
              {remove.isPending ? t('pod.content.deleting') : t('pod.content.confirm_conversation_deletion')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}

function SignOutButton() {
  const { t } = useTranslation()
  const label = t('pod.sidebar.sign_out')
  const signOut = useMutation({
    mutationFn: endPodSession,
    onSettled: () => {
      const tenant = podID()
      window.location.assign(`/sessions/new${tenant ? `?${new URLSearchParams({ tenant_id: tenant })}` : ''}`)
    }
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
