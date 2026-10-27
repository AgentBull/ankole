import {
  Button,
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  useTreeItemDrag,
  TreeDropIndicator
} from '@ankole/uikit'
import {
  RiArrowUpLine,
  RiArrowDownLine,
  RiCornerUpRightLine,
  RiDragMove2Line,
  RiEditLine,
  RiCloseLine,
  RiMoreLine,
  RiLoader4Line
} from '@remixicon/react'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail, ConversationPendingInput, ConversationQueueRequest } from '../api'

type Queue = ConversationDetail['pendingQueues'][number]
export function QueuedStrip({
  detail,
  disabled,
  editing,
  pending,
  callableAgentUIDs,
  change,
  edit,
  takeBack
}: {
  detail: ConversationDetail
  disabled: boolean
  editing: boolean
  pending?: Pick<ConversationQueueRequest, 'action' | 'agentUID' | 'messageID'>
  callableAgentUIDs: string[]
  change(command: ConversationQueueRequest): void
  edit(input: ConversationPendingInput, agentUID: string): void
  takeBack(input: ConversationPendingInput, agentUID: string): void
}) {
  const { t } = useTranslation()
  return (
    <div className="pod-chat-queued-strip">
      {detail.pendingQueues.some(queue => queue.inputs.length > 0) && (
        <p className="pod-chat-queue-hint">{t('pod.chat_room.queue_waiting')}</p>
      )}
      {detail.pendingQueues
        .filter(queue => queue.inputs.length || queue.paused)
        .map(queue => (
          <section
            key={queue.agentUID}
            className="pod-chat-queue"
            aria-label={t('pod.chat.queue_title')}
            aria-busy={pending?.agentUID === queue.agentUID}>
            <div className="pod-chat-queue-header">
              <h2>
                {detail.conversation.agents.find(agent => agent.uid === queue.agentUID)?.displayName} ·{' '}
                {t(queue.paused ? 'pod.chat.queue_paused' : 'pod.chat.queue_title')} ({queue.inputs.length})
              </h2>
              {pending?.agentUID === queue.agentUID && pending.action === 'reorder' && (
                <RiLoader4Line className="size-3 animate-spin" aria-label={t('common.loading')} role="status" />
              )}
              {queue.paused && (
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={disabled || !callableAgentUIDs.includes(queue.agentUID)}
                  onClick={() =>
                    change({ action: 'resume', agentUID: queue.agentUID, expectedVersion: queue.queueVersion })
                  }>
                  {pending?.agentUID === queue.agentUID && pending.action === 'resume' && (
                    <RiLoader4Line className="size-3 animate-spin" aria-hidden />
                  )}
                  {t('pod.chat.resume_queue')}
                </Button>
              )}
            </div>
            <ol className="pod-chat-queue-items">
              {queue.inputs.map((input, index) => (
                <QueuedRow
                  key={input.messageID}
                  input={input}
                  queue={queue}
                  index={index}
                  disabled={disabled || !callableAgentUIDs.includes(queue.agentUID)}
                  editing={editing}
                  pending={
                    pending?.agentUID === queue.agentUID && pending.messageID === input.messageID
                      ? pending.action
                      : undefined
                  }
                  own={input.authorUID === detail.conversation.viewer.uid}
                  change={change}
                  edit={edit}
                  takeBack={takeBack}
                />
              ))}
            </ol>
          </section>
        ))}
    </div>
  )
}

function QueuedRow({
  input,
  queue,
  index,
  disabled,
  editing,
  pending,
  own,
  change,
  edit,
  takeBack
}: {
  input: ConversationPendingInput
  queue: Queue
  index: number
  disabled: boolean
  editing: boolean
  pending?: ConversationQueueRequest['action']
  own: boolean
  change(command: ConversationQueueRequest): void
  edit(input: ConversationPendingInput, agentUID: string): void
  takeBack(input: ConversationPendingInput, agentUID: string): void
}) {
  const { t } = useTranslation()
  const label =
    input.text.trim() ||
    input.attachments.map(attachment => attachment.name).join(', ') ||
    t('pod.chat_room.queue_attachment')
  const reorder = (target: number) => {
    const ids = queue.inputs.map(item => item.messageID)
    ids.splice(index, 1)
    ids.splice(target, 0, input.messageID)
    change({ action: 'reorder', agentUID: queue.agentUID, expectedVersion: queue.queueVersion, messageIDs: ids })
  }
  const drag = useTreeItemDrag<HTMLSpanElement, HTMLLIElement>({
    tree: `pod-chat-queue:${queue.agentUID}`,
    id: input.messageID,
    label,
    canDrag: !disabled,
    availability: (_, operation) => (!disabled && operation !== 'inside' ? 'available' : 'not-available'),
    onDrop: ({ source, operation }) => {
      const ids = queue.inputs.map(item => item.messageID).filter(id => id !== source)
      const target = ids.indexOf(input.messageID) + (operation === 'after' ? 1 : 0)
      ids.splice(target, 0, source)
      change({ action: 'reorder', agentUID: queue.agentUID, expectedVersion: queue.queueVersion, messageIDs: ids })
    }
  })
  return (
    <li ref={drag.targetRef} className="pod-chat-queue-item">
      <TreeDropIndicator indication={drag.indication} />
      <span ref={drag.handleRef} className="pod-chat-drag-handle" aria-hidden>
        <RiDragMove2Line className="size-3.5" />
      </span>
      <span className="pod-chat-queue-position">{index + 1}</span>
      <p className="pod-chat-queue-text" title={label}>
        {label}
      </p>
      {!!input.attachments.length && (
        <span className="pod-chat-queue-files" title={input.attachments.map(attachment => attachment.name).join(', ')}>
          +{input.attachments.length}
        </span>
      )}
      {(own || queue.inputs.length > 1) && (
        <div className="pod-chat-queue-actions">
          {own && (
            <>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.chat_room.steer_now')}
                title={t('pod.chat_room.steer_now')}
                disabled={disabled}
                onClick={() =>
                  change({
                    action: 'steer',
                    agentUID: queue.agentUID,
                    messageID: input.messageID,
                    expectedVersion: queue.queueVersion
                  })
                }>
                {pending === 'steer' ? (
                  <RiLoader4Line className="animate-spin" aria-hidden />
                ) : (
                  <RiCornerUpRightLine aria-hidden />
                )}
              </Button>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.chat.edit_pending')}
                title={t('pod.chat.edit_pending')}
                disabled={disabled || editing}
                onClick={() => edit(input, queue.agentUID)}>
                <RiEditLine aria-hidden />
              </Button>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.chat_room.take_back')}
                title={t('pod.chat_room.take_back')}
                disabled={disabled || editing}
                onClick={() => takeBack(input, queue.agentUID)}>
                {pending === 'retract' ? (
                  <RiLoader4Line className="animate-spin" aria-hidden />
                ) : (
                  <RiCloseLine aria-hidden />
                )}
              </Button>
            </>
          )}
          {queue.inputs.length > 1 && (
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button
                    size="icon-xs"
                    variant="ghost"
                    aria-label={t('pod.chat_room.queue_actions')}
                    title={t('pod.chat_room.queue_actions')}
                    disabled={disabled}
                  />
                }>
                <RiMoreLine aria-hidden />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem disabled={index === 0} onClick={() => reorder(index - 1)}>
                  <RiArrowUpLine aria-hidden />
                  {t('pod.chat_room.move_up')}
                </DropdownMenuItem>
                <DropdownMenuItem disabled={index === queue.inputs.length - 1} onClick={() => reorder(index + 1)}>
                  <RiArrowDownLine aria-hidden />
                  {t('pod.chat_room.move_down')}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          )}
        </div>
      )}
    </li>
  )
}
