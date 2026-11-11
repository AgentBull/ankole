import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Input,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuShortcut,
  toast
} from '@ankole/uikit'
import {
  ArrowDownloadRegular,
  DeleteRegular,
  EditRegular,
  InfoRegular,
  MoreHorizontalRegular,
  PersonAddRegular,
  PinRegular,
  SearchRegular,
  ShareRegular,
  SignOutRegular
} from '@ankole/uikit/icons'
import { useQueryClient } from '@tanstack/react-query'
import { useState, useEffect, useRef, type RefObject } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import { podKeys, type ConversationDetail } from '../api'
import { linkTarget } from '../../common/router'
import { podLocation } from '../../common/browser-context'
import { usePageHref } from '../use-page-metadata'
import { AgentName, agentLabel, conversationPath } from './conversation-row'
import { ParticipantsPopover } from './participants-popover'
import { useRoomActions } from './room-api'
import { exportConversation } from './room-export'
import type { PanelInputEvent } from '../panel-motion'
import { isApplePlatform } from '../../common/platform'
import { PodTopBarActions, PodTopBarPeople } from '../top-bar'

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
  const moreTrigger = useRef<HTMLButtonElement>(null)
  // Rename and find move focus into their own field, so the menu leaves focus where they put it.
  const keepMenuFocus = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepMenuFocus.current
    keepMenuFocus.current = false
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
        {colleague ? (
          <h1 className="m-0 min-w-0 truncate text-sm leading-none" title={agentLabel(colleague)}>
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
              className="w-auto max-w-full min-w-16 py-1 [field-sizing:content]"
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
          <h1 className="m-0 min-w-0 text-sm leading-none">
            <button
              type="button"
              className="pod-chat-header-title max-w-full"
              title={room.title || t('pod.chat_room.rename')}
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
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                ref={moreTrigger}
                size="icon-sm"
                variant="ghost"
                aria-label={t('pod.chat_room.more')}
                title={t('pod.chat_room.more')}
              />
            }>
            <MoreHorizontalRegular aria-hidden />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" finalFocus={menuFinalFocus}>
            <DropdownMenuItem
              aria-keyshortcuts="Meta+F Control+F"
              onClick={() => {
                // The find bar takes focus, and closing it returns focus to this menu's trigger.
                keepMenuFocus.current = true
                moreTrigger.current?.focus()
                onFind()
              }}>
              <SearchRegular aria-hidden />
              {t('pod.chat_room.find')}
              <DropdownMenuShortcut>{isApplePlatform() ? '⌘F' : 'Ctrl+F'}</DropdownMenuShortcut>
            </DropdownMenuItem>
            {!colleague && (
              <DropdownMenuItem
                disabled={!canParticipate}
                onClick={() => {
                  keepMenuFocus.current = true
                  saving.current = false
                  setTitle(room.title)
                  onEditingChange(true)
                }}>
                <EditRegular aria-hidden />
                {t('pod.chat_room.rename')}
              </DropdownMenuItem>
            )}
            <DropdownMenuItem onClick={() => actions.update.mutate({ pinned: !room.viewer.pinned })}>
              <PinRegular aria-hidden />
              {t(room.viewer.pinned ? 'pod.chat_room.unpin' : 'pod.chat_room.pin')}
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => void exportConversation(detail)}>
              <ArrowDownloadRegular aria-hidden />
              {t('pod.chat_room.export')}
            </DropdownMenuItem>
            {room.canDelete && (
              <DropdownMenuItem variant="destructive" onClick={onDelete}>
                <DeleteRegular aria-hidden />
                {t('pod.chat_room.delete')}
              </DropdownMenuItem>
            )}
            {!room.canDelete && room.accessScope === 'participants' && (
              <DropdownMenuItem
                variant="destructive"
                disabled={actions.participants.isPending}
                onClick={() => setLeaving(true)}>
                <SignOutRegular aria-hidden />
                {t('pod.chat_room.leave')}
              </DropdownMenuItem>
            )}
          </DropdownMenuContent>
        </DropdownMenu>
        {/* The room's people lead the end of the shell's top bar, before its search button, and the room's sharing
            actions follow that button; the room header keeps its title, find, and more actions. */}
        <PodTopBarPeople>
          <ParticipantsPopover room={room} />
        </PodTopBarPeople>
        <PodTopBarActions>
          <div className="pod-room-actions flex shrink-0 items-center gap-2">
            <Button
              size="sm"
              variant="ghost"
              aria-label={inviteLabel}
              title={inviteLabel}
              onClick={onInvite}
              disabled={!canParticipate}>
              <PersonAddRegular aria-hidden />
              <span className="pod-chat-invite-label">{inviteLabel}</span>
            </Button>
            <Button
              size="icon-lg"
              variant="ghost"
              aria-label={t('pod.chat_room.copy_link')}
              title={t('pod.chat_room.copy_link')}
              onClick={() => {
                void navigator.clipboard.writeText(new URL(conversationPath(room), location.origin).href).then(
                  () => toast.success(t('pod.chat_room.link_copied')),
                  () => toast.error(t('pod.chat_room.copy_failed'))
                )
              }}>
              <ShareRegular aria-hidden />
            </Button>
            <Button
              ref={summaryTrigger}
              size="icon-lg"
              variant="ghost"
              aria-label={t('pod.chat_room.summary')}
              title={t('pod.chat_room.summary')}
              aria-keyshortcuts="Meta+I Control+I"
              aria-expanded={summaryOpen}
              // The open summary panel is the button's feedback, so the button keeps its resting look while it is open.
              className="aria-expanded:bg-transparent aria-expanded:text-muted-foreground hover:aria-expanded:bg-accent hover:aria-expanded:text-foreground"
              onClick={onSummary}>
              <InfoRegular aria-hidden />
            </Button>
          </div>
        </PodTopBarActions>
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
