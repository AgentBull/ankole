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
  RiAddLine,
  RiMoreLine,
  RiPushpinLine,
  RiNotificationOffLine,
  RiNotificationLine,
  RiDeleteBinLine,
  RiLogoutBoxLine
} from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Link, useLocation, useNavigate } from '@tanstack/react-router'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import { podKeys, chatError } from '../api'
import {
  podConversations,
  updateConversation,
  deleteConversation,
  updateConversationParticipants
} from '../api/generated/sdk.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { contentError } from '../content-errors'
import type { RoomUpdate } from './room-api'
import { ChatAvatar } from './chat-avatar'

export type RoomRow = NonNullable<Awaited<ReturnType<typeof podConversations>>>['conversations'][number]
export function conversationSection(
  date: string | null | undefined,
  now = new Date()
): 'today' | 'yesterday' | 'week' | 'older' {
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const activity = date ? new Date(date).getTime() : 0
  return activity >= day
    ? 'today'
    : activity >= day - 86400000
      ? 'yesterday'
      : activity >= day - 7 * 86400000
        ? 'week'
        : 'older'
}

export function ChatSidebar() {
  const { t } = useTranslation()
  const client = useQueryClient(),
    navigate = useNavigate(),
    location = useLocation()
  const { isMobile, setOpenMobile } = useSidebar()
  const [deleting, setDeleting] = useState<RoomRow>(),
    [leaving, setLeaving] = useState<RoomRow>(),
    [renaming, setRenaming] = useState<string>()
  const keepFocusInRow = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInRow.current
    keepFocusInRow.current = false
    return restore
  }
  const rooms = useInfiniteQuery({
    queryKey: [...podKeys.conversations, 'sidebar'],
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => podConversations({ query: { cursor: pageParam, limit: 40 }, signal }),
    getNextPageParam: last => last.nextCursor ?? undefined
  })
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
      if (room.pageID) void client.invalidateQueries({ queryKey: podKeys.pageConversations(room.pageID) })
      if (location.pathname === podLocation(`/conversations/${room.id}`).pathname) {
        void navigate({ to: podLocation('/').pathname })
      }
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
      if (location.pathname === podLocation(`/conversations/${room.id}`).pathname) {
        void navigate({ to: podLocation('/').pathname })
      }
    },
    onError
  })
  const sections = new Map<string, RoomRow[]>()
  for (const room of rooms.data?.pages.flatMap(page => page.conversations) ?? []) {
    const key = room.viewer.pinned ? 'pinned' : conversationSection(room.lastActivityAt)
    sections.set(key, [...(sections.get(key) ?? []), room])
  }
  const close = () => {
    if (isMobile) setOpenMobile(false)
  }
  const newChatPath = podLocation('/').pathname
  return (
    <div className="pod-chat-sidebar">
      <div className="pb-1">
        <Link
          to={newChatPath}
          className="pod-nav-link"
          aria-current={location.pathname === newChatPath ? 'page' : undefined}
          onClick={close}>
          <RiAddLine aria-hidden />
          <span className="truncate">{t('pod.chat.new_conversation')}</span>
        </Link>
      </div>
      {rooms.isPending && (
        <p role="status" className="p-2">
          {t('pod.chat.loading_history')}
        </p>
      )}
      {rooms.error && (
        <div className="p-2">
          <p role="alert">{t('pod.chat.history_failed')}</p>
          <Button size="xs" variant="outline" onClick={() => void rooms.refetch()}>
            {t('pod.chat.retry_load')}
          </Button>
        </div>
      )}
      {['pinned', 'today', 'yesterday', 'week', 'older']
        .filter(key => sections.has(key))
        .map(section => (
          <section key={section}>
            <h3 className="pod-chat-section-label">{t(`pod.chat_room.section_${section}`)}</h3>
            <SidebarMenu>
              {sections.get(section)!.map(room => {
                const isRenaming = renaming === room.id
                const menu = (
                  <>
                    <DropdownMenuItem
                      onClick={() => {
                        keepFocusInRow.current = true
                        setRenaming(room.id)
                      }}>
                      {t('pod.chat_room.rename')}
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      onClick={() => update.mutate({ id: room.id, data: { pinned: !room.viewer.pinned } })}>
                      <RiPushpinLine aria-hidden />
                      {t(room.viewer.pinned ? 'pod.chat_room.unpin' : 'pod.chat_room.pin')}
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      onClick={() => update.mutate({ id: room.id, data: { muted: !room.viewer.muted } })}>
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
                      <DropdownMenuItem
                        variant="destructive"
                        onClick={() => setLeaving(room)}
                        disabled={leave.isPending}>
                        <RiLogoutBoxLine aria-hidden />
                        {t('pod.chat_room.leave')}
                      </DropdownMenuItem>
                    )}
                  </>
                )
                return (
                  <ContextMenu key={room.id}>
                    <ContextMenuTrigger render={<SidebarMenuItem className="pod-chat-row flex items-center" />}>
                      {isRenaming ? (
                        <ChatRenameField room={room} onDone={() => setRenaming(undefined)} />
                      ) : (
                        <>
                          <SidebarMenuButton
                            render={<Link to={podLocation(`/conversations/${room.id}`).pathname} />}
                            isActive={location.pathname === podLocation(`/conversations/${room.id}`).pathname}
                            onClick={close}
                            title={room.title}>
                            {room.agents.length > 0 && (
                              <span className="pod-chat-avatar-cluster">
                                {room.agents.slice(0, 2).map(agent => (
                                  <ChatAvatar key={agent.uid} name={agent.displayName} src={agent.avatarURL} agent />
                                ))}
                              </span>
                            )}
                            <span>{room.title}</span>
                            {room.viewer.muted && (
                              <RiNotificationOffLine className="size-3 shrink-0" aria-label={t('pod.chat_room.mute')} />
                            )}
                          </SidebarMenuButton>
                          <span className="pod-chat-row-status">
                            <ChatRowStatus status={room.rowStatus} />
                          </span>
                          <DropdownMenu>
                            <DropdownMenuTrigger
                              className="pod-chat-row-menu"
                              render={
                                <Button
                                  size="icon-xs"
                                  variant="ghost"
                                  aria-label={t('pod.chat_room.room_actions', { title: room.title })}
                                />
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
              })}
            </SidebarMenu>
          </section>
        ))}
      {!rooms.isPending && !rooms.error && !sections.size && (
        <p className="p-2 text-fg-tertiary">{t('pod.sidebar.chat_empty')}</p>
      )}
      {rooms.hasNextPage && (
        <Button
          className="w-full"
          size="sm"
          variant="ghost"
          disabled={rooms.isFetchingNextPage}
          onClick={() => void rooms.fetchNextPage()}>
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

export function ChatRowStatus({ status }: { status: RoomRow['rowStatus'] }) {
  const { t } = useTranslation()
  if (status === 'idle') return null
  return (
    <span role="img" aria-label={t(`pod.chat_room.status_${status}`)} title={t(`pod.chat_room.status_${status}`)}>
      <span className={`pod-chat-status-dot pod-chat-status-${status}`} />
    </span>
  )
}
