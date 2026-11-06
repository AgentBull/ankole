import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
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
import { usePageHref } from '../use-page-metadata'
import { ChatAvatar } from './chat-avatar'
import { AgentName, agentLabel, conversationPath } from './conversation-row'
import { useRoomActions } from './room-api'
import { exportConversation } from './room-export'
import type { PanelInputEvent } from '../panel-motion'

export function RoomHeader({
  detail,
  onInvite,
  onFind,
  onSummary,
  summaryOpen,
  summaryTrigger,
  onDelete,
  onExitConversation,
  editing,
  onEditingChange
}: {
  detail: ConversationDetail
  onInvite(): void
  onFind(): void
  onSummary(event?: PanelInputEvent): void
  summaryOpen: boolean
  summaryTrigger?: RefObject<HTMLButtonElement | null>
  onDelete(): void
  onExitConversation?: () => void
  editing: boolean
  onEditingChange(editing: boolean): void
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const { state } = useSidebar()
  const client = useQueryClient()
  const room = detail.conversation
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  // A group invites into itself; a task or a DM stays as it is and starts a separate group.
  const inviteLabel = t(
    room.conversationKind === 'group'
      ? 'pod.chat_room.invite'
      : room.conversationKind === 'assistant_task'
        ? 'pod.superagent.convert_to_group'
        : 'pod.superagent.new_group'
  )
  const canParticipate = room.canManage || room.participants.some(member => member.uid === room.viewer.uid)
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
  return (
    <>
      <header className="pod-chat-header pod-room-header">
        <SidebarTrigger className={state === 'expanded' ? 'md:hidden' : undefined} label={t('pod.sidebar.expand')} />
        {colleague ? (
          <h1 className="m-0 min-w-0 flex-1 truncate text-sm leading-none" title={agentLabel(colleague)}>
            <AgentName agent={colleague} />
          </h1>
        ) : editing ? (
          <form
            className="pod-room-title-form"
            onSubmit={event => {
              event.preventDefault()
              save()
            }}>
            <Input
              ref={input}
              variant="inline"
              className="w-full py-1"
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
          <h1 className="m-0 min-w-0 flex-1 text-sm leading-none">
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
              {room.title || t('pod.content.untitled')}
            </button>
          </h1>
        )}
        {room.pageID && (
          <Link
            className="pod-chat-anchor"
            {...linkTarget(
              podLocation(pageHref(room.pageID), room.conversationKind === 'assistant_task' ? { chat: room.id } : {})
            )}>
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
          // The avatars show who is here: a group's member popover, otherwise the summary's member list.
          // Starting a group from a task or DM stays on its own labelled button.
          aria-expanded={room.conversationKind === 'group' ? undefined : summaryOpen}
          onClick={room.conversationKind === 'group' ? onInvite : onSummary}>
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
          aria-label={inviteLabel}
          title={inviteLabel}
          onClick={onInvite}
          disabled={!canParticipate}>
          <RiUserAddLine aria-hidden />
          <span className="pod-chat-invite-label">{inviteLabel}</span>
        </Button>
        <Button
          size="icon-sm"
          variant="ghost"
          aria-label={t('pod.chat_room.find')}
          title={t('pod.chat_room.find')}
          aria-keyshortcuts="Meta+F Control+F"
          onClick={onFind}>
          <RiSearchLine aria-hidden />
        </Button>
        <Button
          ref={summaryTrigger}
          size="icon-sm"
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
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.chat_room.more')}
                title={t('pod.chat_room.more')}
              />
            }>
            <RiMoreLine aria-hidden />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" finalFocus={menuFinalFocus}>
            {!colleague && (
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
            )}
            <DropdownMenuItem onClick={() => actions.update.mutate({ pinned: !room.viewer.pinned })}>
              <RiPushpinLine aria-hidden />
              {t(room.viewer.pinned ? 'pod.chat_room.unpin' : 'pod.chat_room.pin')}
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() => {
                void navigator.clipboard.writeText(new URL(conversationPath(room), location.origin).href).then(
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
      </header>
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
