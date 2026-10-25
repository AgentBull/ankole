import {
  Button,
  Input,
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
  RiInformationLine,
  RiSearchLine,
  RiMoreLine,
  RiLink,
  RiDownloadLine,
  RiPushpinLine,
  RiDeleteBinLine,
  RiLogoutBoxLine
} from '@remixicon/react'
import { useState, useEffect, useRef, type RefObject } from 'react'
import { Link } from '@tanstack/react-router'
import { useNavigate } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail } from '../api'
import { linkTarget } from '../../common/router'
import { podLocation } from '../../common/browser-context'
import { ChatAvatar } from './chat-avatar'
import { useRoomActions } from './room-api'
import { exportConversation } from './room-export'

export function RoomHeader({
  detail,
  onInvite,
  onFind,
  onSummary,
  summaryOpen,
  summaryTrigger,
  embedded = false,
  onDelete,
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
  onDelete(): void
  editing: boolean
  onEditingChange(editing: boolean): void
}) {
  const { t } = useTranslation()
  const { state } = useSidebar()
  const room = detail.conversation
  const canParticipate = room.canManage || room.participants.some(member => member.uid === room.viewer.uid)
  const Title = embedded ? 'h3' : 'h1'
  const actions = useRoomActions(room.id)
  const navigate = useNavigate()
  const [title, setTitle] = useState(room.title)
  const input = useRef<HTMLInputElement>(null)
  const saving = useRef(false)
  useEffect(() => {
    if (!editing) setTitle(room.title)
  }, [editing, room.title])
  useEffect(() => {
    if (editing) {
      saving.current = false
      input.current?.select()
    }
  }, [editing])
  const save = () => {
    if (saving.current || !canParticipate) return
    saving.current = true
    actions.update.mutate(
      { title: title.trim() },
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
  return (
    <header className="pod-chat-header pod-room-header">
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
              if (event.key === 'Escape') {
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
      {room.pageID && (
        <Link className="pod-chat-anchor" {...linkTarget(podLocation(`/pages/${room.pageID}`, { chat: room.id }))}>
          {t('pod.chat_room.page_context')}
        </Link>
      )}
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
      <Button
        size="sm"
        variant="ghost"
        aria-label={t('pod.chat_room.invite')}
        onClick={onInvite}
        disabled={!canParticipate}>
        <RiAddLine aria-hidden />
        <span className="pod-chat-invite-label">{t('pod.chat_room.invite')}</span>
      </Button>
      <Button
        size="icon-sm"
        variant="ghost"
        aria-label={t('pod.chat_room.find')}
        aria-keyshortcuts="Meta+F Control+F"
        onClick={onFind}>
        <RiSearchLine aria-hidden />
      </Button>
      <Button
        ref={summaryTrigger}
        size="icon-sm"
        variant="ghost"
        aria-label={t('pod.chat_room.summary')}
        aria-keyshortcuts="Meta+I Control+I"
        aria-expanded={summaryOpen}
        onClick={onSummary}>
        <RiInformationLine aria-hidden />
      </Button>
      <DropdownMenu>
        <DropdownMenuTrigger render={<Button size="icon-sm" variant="ghost" aria-label={t('pod.chat_room.more')} />}>
          <RiMoreLine aria-hidden />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem
            disabled={!canParticipate}
            onClick={() => {
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
              onClick={() =>
                actions.participants.mutate(
                  { removeUIDs: [room.viewer.uid] },
                  { onSuccess: () => void navigate({ to: podLocation('/').pathname }) }
                )
              }>
              <RiLogoutBoxLine aria-hidden />
              {t('pod.chat_room.leave')}
            </DropdownMenuItem>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
    </header>
  )
}
