import { useMenuFinalFocus } from '@ankole/uikit/hooks/use-menu-final-focus'
import { ContentSkeleton } from '../content-primitives'
import {
  Button,
  Input,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
  ContextMenu,
  ContextMenuTrigger,
  ContextMenuContent,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  Dialog,
  DialogContent,
  DialogTitle,
  DialogFooter,
  toast
} from '@ankole/uikit'
import {
  RiArrowDownSLine,
  RiArrowUpSLine,
  RiMoreLine,
  RiPushpinLine,
  RiNotificationOffLine,
  RiNotificationLine,
  RiDeleteBinLine,
  RiLogoutBoxLine
} from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQueryClient, useQuery } from '@tanstack/react-query'
import { Link, useLocation, useNavigate } from '@tanstack/react-router'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import { podKeys, chatError, agentsQuery, conversationAttentionQuery, type PodAgent } from '../api'
import {
  podConversations,
  updateConversation,
  deleteConversation,
  updateConversationParticipants
} from '../api/generated/sdk.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { contentError } from '../content-errors'
import { formatRelativeTime } from '../../common/date-time'
import { RootSectionToggle, type RootSectionToggleHandle } from '../page-navigation'
import type { RoomUpdate } from './room-api'
import { ChatAvatar } from './chat-avatar'
import {
  AgentName,
  ChatRowStatus,
  ConversationGlyph,
  ConversationTitle,
  conversationLabel,
  conversationPath,
  type RoomRow
} from './conversation-row'
import { useDebouncedValue } from '../../common/use-debounced-value'
import '../chat.css'

const ATTENTION = ['waiting_choice', 'streaming', 'queued', 'running_background', 'unread']
/** Expanding the assistant group shows this many recent tasks before "Show all", so the IM list stays in view. */
const RECENT_TASKS = 5

export function ChatSidebar() {
  const { t, i18n } = useTranslation()
  const client = useQueryClient(),
    navigate = useNavigate(),
    pathname = useLocation({ select: location => location.pathname })
  const { isMobile, setOpenMobile } = useSidebar()
  const [deleting, setDeleting] = useState<RoomRow>(),
    [leaving, setLeaving] = useState<RoomRow>(),
    [renaming, setRenaming] = useState<string>()
  const agents = useQuery(agentsQuery)
  const attention = useQuery(conversationAttentionQuery)
  const [filter, setFilter] = useState('')
  const search = useDebouncedValue(filter, 180)
  // Collapsed, the assistant group still shows every task that needs attention ("peek").
  const [assistant, setAssistant] = useState<'peek' | 'recent' | 'all'>('peek')
  const [needsInputOpen, setNeedsInputOpen] = useState(true)
  const [pinnedOpen, setPinnedOpen] = useState(true)
  const [messagesOpen, setMessagesOpen] = useState(true)
  const [keepFocusInRow, menuFinalFocus] = useMenuFinalFocus()
  // The Chat tab unmounts this list while Home is open, so the unfiltered list stays cached and a return to Chat
  // shows it at once instead of loading it again.
  const gcTime = search ? undefined : Infinity
  const rooms = useInfiniteQuery({
    queryKey: [...podKeys.conversations, 'sidebar', search],
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) =>
      podConversations({ query: { cursor: pageParam, limit: 40, query: search }, signal }),
    getNextPageParam: last => last.nextCursor ?? undefined,
    gcTime
  })
  const imRooms = useInfiniteQuery({
    queryKey: [...podKeys.conversations, 'sidebar', 'im', search],
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) =>
      podConversations({ query: { cursor: pageParam, limit: 40, query: search, imOnly: true }, signal }),
    getNextPageParam: last => last.nextCursor ?? undefined,
    gcTime
  })
  // Rows wait for both lists, so rows drawn early from cached attention data never shift when the full list lands.
  const loading = rooms.isPending || imRooms.isPending
  const onError = (error: unknown) => toast.error(requestErrorMessage(contentError(chatError(error))))
  const update = useMutation({
    mutationFn: ({ id, data }: { id: string; data: RoomUpdate }) =>
      updateConversation({ path: { id }, body: { data } }),
    onSuccess: (_, { id }) => {
      void client.invalidateQueries({ queryKey: podKeys.conversations })
      void client.invalidateQueries({ queryKey: podKeys.detail(id) })
    },
    onError
  })
  const remove = useMutation({
    mutationFn: (room: RoomRow) => deleteConversation({ path: { id: room.id }, query: { forceStop: true } }),
    onSuccess: (_, room) => {
      setDeleting(undefined)
      client.removeQueries({ queryKey: podKeys.detail(room.id) })
      void client.invalidateQueries({ queryKey: podKeys.conversations })
      void client.invalidateQueries({ queryKey: podKeys.agents })
      if (room.pageID) void client.invalidateQueries({ queryKey: podKeys.pageConversations(room.pageID) })
      if (pathname === conversationPath(room)) void navigate({ to: podLocation('/').pathname })
    },
    onError
  })
  const leave = useMutation({
    mutationFn: (room: RoomRow) =>
      updateConversationParticipants({ path: { id: room.id }, body: { data: { removeUIDs: [room.viewer.uid] } } }),
    onSuccess: (_, room) => {
      setLeaving(undefined)
      client.removeQueries({ queryKey: podKeys.detail(room.id) })
      void client.invalidateQueries({ queryKey: podKeys.conversations })
      if (room.pageID) void client.invalidateQueries({ queryKey: podKeys.pageConversations(room.pageID) })
      if (pathname === conversationPath(room)) void navigate({ to: podLocation('/').pathname })
    },
    onError
  })
  const listedRooms = loading
    ? []
    : [
        ...new Map(
          [
            ...(rooms.data?.pages.flatMap(page => page.conversations) ?? []),
            ...(imRooms.data?.pages.flatMap(page => page.conversations) ?? []),
            ...(!search ? (attention.data ?? []) : [])
          ].map(room => [room.id, room])
        ).values()
      ].sort((a, b) => Date.parse(b.lastActivityAt) - Date.parse(a.lastActivityAt))
  const searching = !!search
  const needsInput = searching ? [] : listedRooms.filter(room => room.rowStatus === 'waiting_choice')
  const needsInputIDs = new Set(needsInput.map(room => room.id))
  const remainingRooms = needsInputIDs.size > 0 ? listedRooms.filter(room => !needsInputIDs.has(room.id)) : listedRooms
  const pinned = remainingRooms.filter(room => room.viewer.pinned)
  const tasks = remainingRooms.filter(room => !room.viewer.pinned && room.conversationKind === 'assistant_task')
  const messages = remainingRooms.filter(room => !room.viewer.pinned && room.conversationKind !== 'assistant_task')
  const knownDMs = new Set(
    listedRooms.filter(room => room.conversationKind === 'colleague_dm').map(room => room.agents[0]?.uid)
  )
  const query = search.trim().replace(/^@/, '').toLocaleLowerCase()
  const colleagues = (loading ? [] : (agents.data?.agents ?? [])).filter(
    agent =>
      !knownDMs.has(agent.uid) &&
      `${agent.uid} ${agent.displayName} ${agent.role ?? ''}`.toLocaleLowerCase().includes(query)
  )
  const shownTasks =
    searching || assistant === 'all'
      ? tasks
      : tasks.filter(
          (room, index) => ATTENTION.includes(room.rowStatus) || (assistant === 'recent' && index < RECENT_TASKS)
        )
  const hiddenTasks = tasks.length - shownTasks.length
  useEffect(() => {
    if (assistant !== 'peek' && tasks.length < RECENT_TASKS && rooms.hasNextPage && !rooms.isFetchingNextPage) {
      void rooms.fetchNextPage()
    }
  }, [assistant, tasks.length, rooms.hasNextPage, rooms.isFetchingNextPage, rooms.fetchNextPage])
  const close = () => {
    if (isMobile) setOpenMobile(false)
  }
  const roomRow = (room: RoomRow) => {
    const target = conversationPath(room)
    const dm = room.conversationKind === 'colleague_dm'
    const twoLines = room.conversationKind !== 'assistant_task'
    const title = conversationLabel(room, t('pod.content.untitled'))
    const time = twoLines ? formatRelativeTime(room.lastActivityAt, i18n.language) : ''
    const menu = (
      <>
        {!dm && (
          <DropdownMenuItem
            onClick={() => {
              keepFocusInRow.current = true
              setRenaming(room.id)
            }}>
            {t('pod.chat_room.rename')}
          </DropdownMenuItem>
        )}
        <DropdownMenuItem onClick={() => update.mutate({ id: room.id, data: { pinned: !room.viewer.pinned } })}>
          <RiPushpinLine aria-hidden />
          {t(room.viewer.pinned ? 'pod.chat_room.unpin' : 'pod.chat_room.pin')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => update.mutate({ id: room.id, data: { muted: !room.viewer.muted } })}>
          {room.viewer.muted ? <RiNotificationLine aria-hidden /> : <RiNotificationOffLine aria-hidden />}
          {t(room.viewer.muted ? 'pod.chat_room.unmute' : 'pod.chat_room.mute')}
        </DropdownMenuItem>
        {room.canDelete && (
          <DropdownMenuItem variant="destructive" onClick={() => setDeleting(room)}>
            <RiDeleteBinLine aria-hidden />
            {t('pod.chat_room.delete')}
          </DropdownMenuItem>
        )}
        {!room.canDelete && room.accessScope === 'participants' && (
          <DropdownMenuItem variant="destructive" onClick={() => setLeaving(room)} disabled={leave.isPending}>
            <RiLogoutBoxLine aria-hidden />
            {t('pod.chat_room.leave')}
          </DropdownMenuItem>
        )}
      </>
    )
    const muted = room.viewer.muted && (
      <RiNotificationOffLine className="size-3 shrink-0" aria-label={t('pod.chat_room.mute')} />
    )
    return (
      <ContextMenu key={room.id}>
        <ContextMenuTrigger render={<SidebarMenuItem className="pod-chat-row" data-lines={twoLines ? 2 : 1} />}>
          {renaming === room.id ? (
            <div className="pod-chat-row-editing">
              <ConversationGlyph room={room} size={twoLines ? 'md' : 'sm'} />
              <ChatRenameField room={room} onDone={() => setRenaming(undefined)} />
            </div>
          ) : (
            <>
              <SidebarMenuButton
                render={<Link to={target} />}
                isActive={pathname === target}
                onClick={close}
                title={title}>
                <ConversationGlyph room={room} size={twoLines ? 'md' : 'sm'} />
                {twoLines ? (
                  <span className="pod-chat-row-copy" dir="auto">
                    <span className="pod-chat-row-line">
                      <span className="pod-chat-row-title">
                        <ConversationTitle room={room} />
                      </span>
                      <span className="pod-chat-row-trailing">{time}</span>
                    </span>
                    <span className="pod-chat-row-line">
                      <span className="pod-chat-row-preview">{room.latestMessagePreview}</span>
                      <span className="pod-chat-row-trailing">
                        {muted}
                        <ChatRowStatus status={room.rowStatus} />
                      </span>
                    </span>
                  </span>
                ) : (
                  <span className="pod-chat-row-line" dir="auto">
                    <span className="pod-chat-row-title">
                      <ConversationTitle room={room} />
                    </span>
                    <span className="pod-chat-row-trailing">
                      {muted}
                      <ChatRowStatus status={room.rowStatus} />
                    </span>
                  </span>
                )}
              </SidebarMenuButton>
              <DropdownMenu>
                <DropdownMenuTrigger
                  className="pod-chat-row-menu"
                  render={
                    <Button size="icon-xs" variant="ghost" aria-label={t('pod.chat_room.room_actions', { title })} />
                  }>
                  <RiMoreLine aria-hidden />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" finalFocus={menuFinalFocus}>
                  {menu}
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          )}
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
    )
  }
  const colleagueRow = (agent: PodAgent) => {
    const target = podLocation(`/dm/${encodeURIComponent(agent.uid)}`).pathname
    return (
      <SidebarMenuItem key={agent.uid} className="pod-chat-row" data-lines={2}>
        <SidebarMenuButton render={<Link to={target} />} isActive={pathname === target} onClick={close}>
          <span className="pod-conversation-glyph" data-size="md">
            <ChatAvatar name={agent.displayName} src={agent.avatarURL} agent />
          </span>
          <span className="pod-chat-row-copy">
            <span className="pod-chat-row-line">
              <span className="pod-chat-row-title">
                <AgentName agent={agent} />
              </span>
            </span>
            <span className="pod-chat-row-line">
              <span className="pod-chat-row-preview">{agent.role}</span>
            </span>
          </span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    )
  }
  const loadedTasks = `${tasks.length}${rooms.hasNextPage ? '+' : ''}`
  return (
    <div className="pod-chat-sidebar">
      <Input
        className="pod-chat-filter"
        type="search"
        value={filter}
        onChange={event => setFilter(event.target.value)}
        onKeyDown={event => {
          if (event.key === 'Escape' && filter) {
            event.preventDefault()
            setFilter('')
          }
        }}
        aria-label={t('pod.superagent.filter')}
        placeholder={t('pod.superagent.filter')}
      />
      {loading && (
        <ContentSkeleton variant="list" rows={4} label={t('pod.chat.loading_history')} className="pod-tree-empty" />
      )}
      {(rooms.error || imRooms.error) && (
        <div className="p-2">
          <p role="alert">{t('pod.chat.history_failed')}</p>
          <Button
            size="xs"
            variant="outline"
            onClick={() => {
              void rooms.refetch()
              void imRooms.refetch()
            }}>
            {t('pod.chat.retry_load')}
          </Button>
        </div>
      )}
      {needsInput.length > 0 && (
        <ChatSection
          label={t('pod.chat_room.section_needs_input')}
          count={String(needsInput.length)}
          open={needsInputOpen}
          onToggle={() => setNeedsInputOpen(!needsInputOpen)}>
          {needsInputOpen && needsInput.map(roomRow)}
        </ChatSection>
      )}
      {pinned.length > 0 && (
        <ChatSection
          label={t('pod.chat_room.section_pinned')}
          open={pinnedOpen || searching}
          onToggle={() => setPinnedOpen(!pinnedOpen)}>
          {(pinnedOpen || searching) && pinned.map(roomRow)}
        </ChatSection>
      )}
      {tasks.length > 0 && (
        <ChatSection
          label={t('pod.chat.personal_assistant')}
          count={loadedTasks}
          open={assistant !== 'peek' || searching}
          onToggle={() => setAssistant(assistant === 'peek' ? 'recent' : 'peek')}
          footer={
            !searching &&
            assistant !== 'peek' &&
            (hiddenTasks > 0 || assistant === 'all') && (
              <button
                type="button"
                className="nav-row pod-nav-link pod-chat-section-more"
                onClick={() => {
                  if (assistant === 'all') {
                    if (rooms.hasNextPage) void rooms.fetchNextPage()
                    else setAssistant('recent')
                  } else setAssistant('all')
                }}>
                {assistant === 'all' && !rooms.hasNextPage ? (
                  <RiArrowUpSLine aria-hidden />
                ) : (
                  <RiArrowDownSLine aria-hidden />
                )}
                <span>
                  {assistant === 'all'
                    ? t(rooms.hasNextPage ? 'pod.superagent.show_more' : 'pod.superagent.show_less')
                    : t('pod.superagent.show_all', { count: hiddenTasks })}
                </span>
              </button>
            )
          }>
          {shownTasks.map(roomRow)}
        </ChatSection>
      )}
      {(messages.length > 0 || colleagues.length > 0) && (
        <ChatSection
          label={t('pod.superagent.messages_colleagues')}
          open={messagesOpen || searching}
          onToggle={() => setMessagesOpen(!messagesOpen)}>
          {(messagesOpen || searching) && [...messages.map(roomRow), ...colleagues.map(colleagueRow)]}
        </ChatSection>
      )}
      {!loading && !rooms.error && !listedRooms.length && !colleagues.length && (
        <p className="pod-tree-empty">{t(searching ? 'pod.superagent.no_matches' : 'pod.sidebar.chat_empty')}</p>
      )}
      {imRooms.hasNextPage && (
        <Button
          className="w-full"
          size="sm"
          variant="ghost"
          disabled={imRooms.isFetchingNextPage}
          onClick={() => void imRooms.fetchNextPage()}>
          {t('pod.chat_room.load_more')}
        </Button>
      )}
      <Dialog open={!!leaving} onOpenChange={open => !open && !leave.isPending && setLeaving(undefined)}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.chat_room.leave')}</DialogTitle>
          <p className="text-sm">
            {t('pod.chat_room.leave_confirm', {
              title: leaving?.title ?? '',
              defaultValue: 'Leave “{$title}”? You will need a new invitation to rejoin.'
            })}
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setLeaving(undefined)} disabled={leave.isPending}>
              {t('common.cancel')}
            </Button>
            <Button variant="destructive" disabled={leave.isPending} onClick={() => leaving && leave.mutate(leaving)}>
              {t('pod.chat_room.leave')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={!!deleting} onOpenChange={open => !open && !remove.isPending && setDeleting(undefined)}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogTitle>
            {t(
              deleting && ['streaming', 'queued', 'running_background', 'waiting_choice'].includes(deleting.rowStatus)
                ? 'pod.chat_room.stop_delete'
                : 'pod.chat_room.delete'
            )}
          </DialogTitle>
          <p className="text-sm">
            {t('pod.content.deleting_cannot_be_undone_pages_saved_to_pod_will_be', { title: deleting?.title ?? '' })}
          </p>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleting(undefined)} disabled={remove.isPending}>
              {t('pod.content.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={remove.isPending}
              onClick={() => deleting && remove.mutate(deleting)}>
              {t(
                deleting && ['streaming', 'queued', 'running_background', 'waiting_choice'].includes(deleting.rowStatus)
                  ? 'pod.chat_room.stop_delete'
                  : 'pod.chat_room.delete'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function ChatRenameField({ room, onDone }: { room: RoomRow; onDone(): void }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [value, setValue] = useState(room.title)
  const finished = useRef(false)
  const finish = () => {
    finished.current = true
    onDone()
  }
  const rename = useMutation({
    mutationFn: (title: string) => updateConversation({ path: { id: room.id }, body: { data: { title } } }),
    onSuccess: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: podKeys.conversations }),
        client.invalidateQueries({ queryKey: podKeys.detail(room.id) })
      ])
      finish()
    },
    onError: error => {
      finished.current = false
      toast.error(requestErrorMessage(contentError(chatError(error))))
    }
  })
  const submit = () => {
    if (finished.current || rename.isPending) return
    const next = value.trim()
    if (!next || next === room.title) return finish()
    finished.current = true
    rename.mutate(next)
  }
  return (
    <Input
      autoFocus
      variant="inline"
      className="pod-chat-row-rename"
      aria-label={t('pod.chat_room.rename')}
      value={value}
      disabled={rename.isPending}
      onFocus={event => event.currentTarget.select()}
      onChange={event => setValue(event.target.value)}
      onBlur={submit}
      onKeyDown={event => {
        if (event.nativeEvent.isComposing || event.keyCode === 229) return
        if (event.key === 'Enter') {
          event.preventDefault()
          submit()
        } else if (event.key === 'Escape') {
          event.preventDefault()
          finish()
        }
      }}
    />
  )
}

/** A Chat sidebar group, headed and toggled the same way as the Home sections. */
function ChatSection({
  label,
  count,
  open,
  onToggle,
  footer,
  children
}: {
  label: string
  count?: string
  open: boolean
  onToggle(): void
  footer?: ReactNode
  children: ReactNode
}) {
  const toggle = useRef<RootSectionToggleHandle>(null)
  return (
    <section aria-label={label} className="pod-nav-section">
      <div className="pod-nav-section-heading">
        <RootSectionToggle ref={toggle} open={open} label={label} onToggle={onToggle} />
        {/* The chevron owns keyboard focus, the expanded state, and the accessible name; this wider target
            serves pointer users, so assistive technology and role locators see one toggle per section. */}
        <button
          type="button"
          tabIndex={-1}
          aria-hidden
          className="pod-chat-section-label"
          onClick={event => toggle.current?.toggle(event.detail)}>
          <span className="min-w-0 flex-1 truncate">{label}</span>
          {count && <span className="pod-chat-section-count">{count}</span>}
        </button>
      </div>
      <SidebarMenu>{children}</SidebarMenu>
      {footer}
    </section>
  )
}
