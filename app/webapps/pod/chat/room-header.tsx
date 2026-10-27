import {
  Button,
  cn,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  SidebarTrigger,
  useSidebar,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  toast
} from '@ankole/uikit'
import {
  RiAddLine,
  RiCloseLine,
  RiExternalLinkLine,
  RiHistoryLine,
  RiInformationLine,
  RiSearchLine,
  RiMoreLine,
  RiLink,
  RiDownloadLine,
  RiPushpinLine,
  RiDeleteBinLine,
  RiLogoutBoxLine,
  RiUserAddLine
} from '@remixicon/react'
import { useQueryClient } from '@tanstack/react-query'
import { useState, useEffect, useRef, type RefObject } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { podKeys, type ConversationDetail } from '../api'
import { linkTarget } from '../../common/router'
import { podLocation } from '../../common/browser-context'
import { ContentError } from '../content-primitives'
import { ChatAvatar } from './chat-avatar'
import { useRoomActions } from './room-api'
import { exportConversation } from './room-export'

export type PageChatHeaderControls = {
  pageTitle: string
  conversations: { id: string; title: string }[]
  conversationsPending: boolean
  listError?: unknown
  onRetryList?: () => void
  accessDenied: boolean
  onSelectConversation(id: string): void
  onNewConversation(): void
  onClose(): void
}

export function RoomHeader({
  detail,
  onInvite,
  onFind,
  onSummary,
  summaryOpen,
  summaryTrigger,
  embedded: embeddedProp = false,
  pageChat,
  onDelete,
  onExitConversation,
  editing,
  onEditingChange
}: {
  detail: ConversationDetail
  onInvite(): void
  onFind(): void
  onSummary(): void
  summaryOpen: boolean
  summaryTrigger?: RefObject<HTMLButtonElement | null>
  embedded?: boolean
  pageChat?: PageChatHeaderControls
  onDelete(): void
  onExitConversation?: () => void
  editing: boolean
  onEditingChange(editing: boolean): void
}) {
  const { t } = useTranslation()
  const { state } = useSidebar()
  const client = useQueryClient()
  const embedded = embeddedProp || Boolean(pageChat)
  const room = detail.conversation
  const canParticipate = room.canManage || room.participants.some(member => member.uid === room.viewer.uid)
  const Title = embedded ? 'h3' : 'h1'
  const actions = useRoomActions(room.id)
  const navigate = useNavigate()
  const [title, setTitle] = useState(room.title)
  const [leaving, setLeaving] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  const saving = useRef(false)
  const keepFocusInTitle = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInTitle.current
    keepFocusInTitle.current = false
    return restore
  }
  useEffect(() => {
    if (!editing) setTitle(room.title)
  }, [editing, room.title])
  useEffect(() => {
    if (editing) {
      saving.current = false
      input.current?.focus()
      input.current?.select()
    }
  }, [editing])
  const save = () => {
    if (saving.current || !canParticipate) return
    const next = title.trim()
    if (!next || next === room.title) {
      saving.current = true
      onEditingChange(false)
      return
    }
    saving.current = true
    actions.update.mutate(
      { title: next },
      {
        onSuccess: () => {
          onEditingChange(false)
        },
        onSettled: () => {
          saving.current = false
        }
      }
    )
  }
  const historyItems = pageChat
    ? pageChat.conversations.some(item => item.id === room.id)
      ? pageChat.conversations
      : [{ id: room.id, title: room.title }, ...pageChat.conversations]
    : []
  return (
    <>
      <header
        className={cn('pod-chat-header pod-room-header', pageChat && 'pod-page-chat-header')}
        title={pageChat?.pageTitle}>
        {!embedded && (
          <SidebarTrigger className={state === 'expanded' ? 'md:hidden' : undefined} label={t('pod.sidebar.expand')} />
        )}
        {editing ? (
          <form
            className="pod-room-title-form"
            onSubmit={event => {
              event.preventDefault()
              save()
            }}>
            <Input
              ref={input}
              aria-label={t('pod.chat_room.rename')}
              value={title}
              onChange={event => setTitle(event.target.value)}
              disabled={actions.update.isPending}
              onBlur={save}
              onKeyDown={event => {
                if (event.nativeEvent.isComposing || event.keyCode === 229) return
                if (event.key === 'Escape') {
                  event.preventDefault()
                  saving.current = true
                  onEditingChange(false)
                }
              }}
            />
          </form>
        ) : (
          <Title className="m-0 min-w-0 flex-1 text-sm leading-none">
            <button
              type="button"
              className="pod-chat-header-title w-full"
              title={t('pod.chat_room.rename')}
              disabled={!canParticipate}
              onClick={() => {
                saving.current = false
                setTitle(room.title)
                onEditingChange(true)
              }}>
              {room.title}
            </button>
          </Title>
        )}
        {room.pageID && !embedded && (
          <Link className="pod-chat-anchor" {...linkTarget(podLocation(`/pages/${room.pageID}`, { chat: room.id }))}>
            {t('pod.chat_room.page_context')}
          </Link>
        )}
        {pageChat && (
          <>
            <div className="pod-page-chat-scope">
              <Select
                value={room.accessScope}
                onValueChange={value => {
                  if ((value === 'participants' || value === 'anchor_page') && value !== room.accessScope) {
                    actions.update.mutate({ accessScope: value })
                  }
                }}
                disabled={pageChat.accessDenied || actions.update.isPending || !room.canManage}>
                <SelectTrigger
                  size="sm"
                  className="pod-page-chat-scope-trigger"
                  aria-label={t('pod.chat_room.visibility')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="participants">{t('pod.chat_room.scope_participants')}</SelectItem>
                  <SelectItem value="anchor_page">{t('pod.chat_room.scope_anchor_page')}</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <Button
              size="icon-xs"
              variant="ghost"
              aria-label={t('pod.chat.new_conversation')}
              title={t('pod.chat.new_conversation')}
              disabled={pageChat.accessDenied}
              onClick={pageChat.onNewConversation}>
              <RiAddLine aria-hidden />
            </Button>
            <Select
              value={room.id}
              onValueChange={id => id && pageChat.onSelectConversation(id)}
              disabled={pageChat.conversationsPending || pageChat.accessDenied}>
              <SelectTrigger
                aria-label={t('pod.page_chat.choose_chat')}
                title={t('pod.page_chat.choose_chat')}
                className="pod-page-chat-switcher"
                size="sm">
                <RiHistoryLine aria-hidden />
                <SelectValue className="sr-only" />
              </SelectTrigger>
              <SelectContent align="end" className="pod-page-chat-history-menu">
                <SelectItem value="new">{t('pod.chat.new_conversation')}</SelectItem>
                {historyItems.map(chat => (
                  <SelectItem key={chat.id} value={chat.id}>
                    {chat.title}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </>
        )}
        {!embedded && (
          <button
            type="button"
            className="pod-chat-avatar-cluster"
            aria-label={t('pod.chat_room.participants_list', {
              names: room.participants.map(member => member.displayName).join(', ')
            })}
            title={room.participants.map(member => member.displayName).join(', ')}
            onClick={onInvite}>
            {room.participants.slice(0, 4).map(member => (
              <ChatAvatar
                key={member.uid}
                name={member.displayName}
                src={member.avatarURL}
                agent={member.type === 'agent'}
              />
            ))}
            {room.participants.length > 4 && (
              <span className="pod-chat-avatar pod-chat-avatar-overflow">+{room.participants.length - 4}</span>
            )}
          </button>
        )}
        <Button
          size={embedded ? 'icon-xs' : 'sm'}
          variant="ghost"
          aria-label={t('pod.chat_room.invite')}
          title={t('pod.chat_room.invite')}
          onClick={onInvite}
          disabled={!canParticipate}>
          <RiUserAddLine aria-hidden />
          {!embedded && <span className="pod-chat-invite-label">{t('pod.chat_room.invite')}</span>}
        </Button>
        {!embedded && (
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('pod.chat_room.find')}
            title={t('pod.chat_room.find')}
            aria-keyshortcuts="Meta+F Control+F"
            onClick={onFind}>
            <RiSearchLine aria-hidden />
          </Button>
        )}
        <Button
          ref={summaryTrigger}
          size={embedded ? 'icon-xs' : 'icon-sm'}
          variant="ghost"
          aria-label={t('pod.chat_room.summary')}
          title={t('pod.chat_room.summary')}
          aria-keyshortcuts="Meta+I Control+I"
          aria-expanded={summaryOpen}
          onClick={onSummary}>
          <RiInformationLine aria-hidden />
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                size={embedded ? 'icon-xs' : 'icon-sm'}
                variant="ghost"
                aria-label={t('pod.chat_room.more')}
                title={t('pod.chat_room.more')}
              />
            }>
            <RiMoreLine aria-hidden />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" finalFocus={menuFinalFocus}>
            {embedded && (
              <DropdownMenuItem onClick={onFind}>
                <RiSearchLine aria-hidden />
                {t('pod.chat_room.find')}
              </DropdownMenuItem>
            )}
            <DropdownMenuItem
              disabled={!canParticipate}
              onClick={() => {
                keepFocusInTitle.current = true
                saving.current = false
                setTitle(room.title)
                onEditingChange(true)
              }}>
              {t('pod.chat_room.rename')}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => actions.update.mutate({ pinned: !room.viewer.pinned })}>
              <RiPushpinLine aria-hidden />
              {t(room.viewer.pinned ? 'pod.chat_room.unpin' : 'pod.chat_room.pin')}
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() => {
                void navigator.clipboard
                  .writeText(new URL(podLocation(`/conversations/${room.id}`).pathname, location.origin).href)
                  .then(
                    () => toast.success(t('pod.chat_room.link_copied')),
                    () => toast.error(t('pod.chat_room.copy_failed'))
                  )
              }}>
              <RiLink aria-hidden />
              {t('pod.chat_room.copy_link')}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => void exportConversation(detail)}>
              <RiDownloadLine aria-hidden />
              {t('pod.chat_room.export')}
            </DropdownMenuItem>
            {room.canDelete && (
              <DropdownMenuItem variant="destructive" onClick={onDelete}>
                <RiDeleteBinLine aria-hidden />
                {t('pod.chat_room.delete')}
              </DropdownMenuItem>
            )}
            {!room.canDelete && room.accessScope === 'participants' && (
              <DropdownMenuItem
                variant="destructive"
                disabled={actions.participants.isPending}
                onClick={() => setLeaving(true)}>
                <RiLogoutBoxLine aria-hidden />
                {t('pod.chat_room.leave')}
              </DropdownMenuItem>
            )}
          </DropdownMenuContent>
        </DropdownMenu>
        {pageChat && (
          <>
            <Button
              size="icon-xs"
              variant="ghost"
              aria-label={t('pod.page_chat.open_chat')}
              title={t('pod.page_chat.open_chat')}
              render={<Link to={podLocation(`/conversations/${room.id}`).pathname} />}
              nativeButton={false}>
              <RiExternalLinkLine aria-hidden />
            </Button>
            <Button
              size="icon-xs"
              variant="ghost"
              aria-label={t('pod.page_chat.close')}
              title={t('pod.page_chat.close')}
              onClick={pageChat.onClose}>
              <RiCloseLine aria-hidden />
            </Button>
          </>
        )}
      </header>
      {pageChat?.listError != null && (
        <div className="border-b border-border px-3 py-1.5">
          <ContentError error={pageChat.listError} retry={pageChat.onRetryList} />
        </div>
      )}
      <Dialog open={leaving} onOpenChange={open => !open && !actions.participants.isPending && setLeaving(false)}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.chat_room.leave')}</DialogTitle>
          <p className="text-sm">
            {t('pod.chat_room.leave_confirm', {
              title: room.title,
              defaultValue: 'Leave “{$title}”? You will need a new invitation to rejoin.'
            })}
          </p>
          <DialogFooter>
            <Button variant="outline" disabled={actions.participants.isPending} onClick={() => setLeaving(false)}>
              {t('common.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={actions.participants.isPending}
              onClick={() =>
                actions.participants.mutate(
                  { removeUIDs: [room.viewer.uid] },
                  {
                    onSuccess: () => {
                      setLeaving(false)
                      client.removeQueries({ queryKey: podKeys.detail(room.id) })
                      void client.invalidateQueries({ queryKey: podKeys.conversations })
                      if (room.pageID) {
                        void client.invalidateQueries({ queryKey: podKeys.pageConversations(room.pageID) })
                      }
                      if (onExitConversation) onExitConversation()
                      else void navigate({ to: podLocation('/').pathname })
                    }
                  }
                )
              }>
              {t('pod.chat_room.leave')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
