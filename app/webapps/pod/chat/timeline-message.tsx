import { cn } from '@ankole/uikit'
import { RiFileTextLine, RiReplyLine } from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import { memo } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail, ConversationMessage } from '../api'
import type { ChatCommands } from '../chat-commands'
import { MessageArtifacts } from '../message-artifacts'
import type { PanelInputEvent } from '../panel-motion'
import { ChatModel } from '../state/chat'
import { usePageHref, usePagesMetadata } from '../use-page-metadata'
import { ActionCardView } from './action-card-view'
import { avatarInitials, ChatAvatar } from './chat-avatar'
import { ChatMarkdown } from './chat-markdown'
import { ChoiceCard, type ClarifyAnswer } from './choice-card'
import { activitySteps, CollapsedWorkView, useActivityLabel } from './collapsed-work-view'
import { InlineMessageEditor } from './inline-message-editor'
import { LinkedExecutionCard } from './linked-execution-card'
import { MessageActions } from './message-actions'
import { PeerExchangeCard } from './peer-exchange-card'
import type { ActionCardDecision } from './room-api'
import {
  filterPromotedExecutionSteps,
  isExecutionActive,
  isPeerActive,
  messageTime,
  timelineEventLabel
} from './timeline-projections'
import type { InspectorTarget, LinkedExecution, TimelineLiveStream, TimelineMessage } from './types'

export type InlineEditControls = {
  canSubmit: boolean
  recipientAvailable: boolean
  submitting: boolean
  editConflict: boolean
  submitError?: unknown
  recovery: ChatCommands['recovery']
  onSubmit(): void
  onCancel(): void
}

/**
 * Who wrote a message. Your own messages and a message that continues the same author's last one keep the
 * name only for assistive technology, so the line shows only the time, on hover.
 */
export function MessageIdentity({
  name,
  human = false,
  archived = false,
  time,
  avatarURL,
  quiet = false
}: {
  name: string
  human?: boolean
  archived?: boolean
  time?: string
  avatarURL?: string | null
  quiet?: boolean
}) {
  const { t, i18n } = useTranslation()
  return (
    <header className="pod-chat-message-identity" data-quiet={quiet || undefined}>
      {!quiet && <ChatAvatar name={name} src={avatarURL} agent={!human} className="pod-chat-message-avatar" />}
      <strong className={quiet ? 'sr-only' : undefined}>{name}</strong>
      {archived && <span className="pod-chat-archived">{t('pod.chat_timeline.archived')}</span>}
      {time && (
        <time dateTime={time} title={new Date(time).toLocaleString(i18n.language)}>
          {messageTime(time, i18n.language)}
        </time>
      )}
    </header>
  )
}

export const CommittedMessage = memo(function CommittedMessage({
  model,
  detail,
  message,
  conversationID,
  peerReply,
  peerLive = false,
  inlineEdit,
  canEdit = false,
  editDisabledReason,
  editingInline = false,
  backtrackActive = false,
  retryable = false,
  onEditMessage,
  onRegenerateMessage,
  onQuoteMessage,
  onSelectMessageID,
  linkedRuns,
  showAgentOnRuns = false,
  activeInspector,
  onOpenInspector,
  replySource,
  onJumpToSource,
  onAnswer,
  onResolveActionCard,
  onComposeAnswer,
  keyboardActive,
  showActions,
  avatarURL,
  own,
  queued,
  continued = false,
  readOnlyReason
}: {
  model: InstanceType<typeof ChatModel>
  detail?: ConversationDetail
  message: TimelineMessage
  conversationID: string
  peerReply?: TimelineMessage
  peerLive?: boolean
  inlineEdit?: InlineEditControls
  canEdit?: boolean
  editDisabledReason?: string
  editingInline?: boolean
  backtrackActive?: boolean
  retryable?: boolean
  onEditMessage?: (message: ConversationMessage) => void
  onRegenerateMessage?: (message: ConversationMessage) => void
  onQuoteMessage?: (text: string, message: ConversationMessage) => void
  onSelectMessageID?: (messageID: string) => void
  linkedRuns: LinkedExecution[]
  showAgentOnRuns?: boolean
  activeInspector?: InspectorTarget | null
  onOpenInspector?: (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) => void
  replySource?: Pick<ConversationMessage, 'id' | 'authorDisplayName' | 'text'>
  onJumpToSource(id: string): void
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onResolveActionCard?: (cardID: string, decision: ActionCardDecision) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  keyboardActive: boolean
  showActions: boolean
  avatarURL?: string | null
  own: boolean
  queued?: boolean
  continued?: boolean
  readOnlyReason?: string
}) {
  const { t, i18n } = useTranslation()
  const pageHref = usePageHref()
  const savedPages = usePagesMetadata(message.savedPages)
  const rich = message.richContent
  const human = message.authorType === 'human'
  const name = message.authorDisplayName
  const onRetry = retryable && onRegenerateMessage ? () => onRegenerateMessage(message) : undefined
  const onEdit = canEdit && onEditMessage ? () => onEditMessage(message) : undefined
  const onQuote = onQuoteMessage ? (text: string) => onQuoteMessage(text, message) : undefined
  const onSelectMessage = onSelectMessageID ? () => onSelectMessageID(message.id) : undefined

  if (message.kind === 'notice' && !rich?.execution) {
    const label = timelineEventLabel(message, t, i18n.language)
    return (
      <div className="pod-chat-timeline-event">
        <span className="pod-chat-event-avatar" aria-hidden>
          {avatarInitials(name)}
        </span>
        <p title={label}>{label}</p>
        <time dateTime={message.createdAt} title={new Date(message.createdAt).toLocaleString(i18n.language)}>
          {messageTime(message.createdAt, i18n.language)}
        </time>
        {onRetry && <MessageActions text="" onRetry={onRetry} alwaysVisible />}
      </div>
    )
  }
  if (rich?.agent_peer_outbound) {
    return (
      <PeerExchangeCard
        conversationID={conversationID}
        peer={rich.agent_peer_outbound}
        request={message}
        reply={peerReply}
        live={peerLive}
        isActive={isPeerActive(activeInspector, rich.agent_peer_outbound.exchange_id)}
        onOpenInspector={onOpenInspector ? (target, trigger) => onOpenInspector(target, trigger) : undefined}
      />
    )
  }
  if (rich?.agent_peer_inbound) {
    return (
      <PeerExchangeCard
        conversationID={conversationID}
        peer={rich.agent_peer_inbound}
        reply={message}
        live={false}
        isActive={isPeerActive(activeInspector, rich.agent_peer_inbound.exchange_id)}
        onOpenInspector={onOpenInspector ? (target, trigger) => onOpenInspector(target, trigger) : undefined}
      />
    )
  }
  const prompt = rich?.clarify
  const actionCard = rich?.action_card
  const visibleExecution = rich?.execution
    ? {
        ...rich.execution,
        steps: filterPromotedExecutionSteps(rich.execution.steps, linkedRuns)
      }
    : undefined
  return (
    <article
      data-backtrack-active={backtrackActive || undefined}
      className={cn(
        'pod-chat-timeline-message',
        human ? 'pod-chat-human-message' : 'pod-chat-agent-message',
        own && 'pod-chat-own-message',
        continued && 'pod-chat-continued-message',
        backtrackActive && !editingInline && 'pod-chat-backtrack-active'
      )}>
      <MessageIdentity
        name={name}
        human={human}
        archived={message.authorArchived}
        time={message.createdAt}
        avatarURL={avatarURL}
        quiet={own || continued || !!rich?.peer_agent_uid}
      />
      {editingInline && detail && inlineEdit ? (
        <InlineMessageEditor model={model} message={message} detail={detail} {...inlineEdit} />
      ) : (
        <>
          {backtrackActive && <span className="pod-chat-backtrack-pill">{t('pod.chat.backtrack_hint')}</span>}
          {queued && <span className="pod-chat-queued-badge">{t('pod.chat_timeline.queued')}</span>}
          {replySource && (
            <button type="button" className="pod-chat-reply-source" onClick={() => onJumpToSource(replySource.id)}>
              <RiReplyLine aria-hidden />
              <span>
                {t('pod.chat_timeline.reply_source', {
                  name: replySource.authorDisplayName,
                  text: replySource.text.replace(/\s+/g, ' ').trim().slice(0, 160) || t('pod.content.attachment')
                })}
              </span>
            </button>
          )}
          {message.links
            .filter(link => link.quote)
            .map(link => (
              <blockquote key={link.id} className="pod-chat-quoted-message">
                {link.quote}
              </blockquote>
            ))}
          {visibleExecution && (
            <CollapsedWorkView
              execution={visibleExecution}
              attention={
                prompt?.state === 'pending' || (!!actionCard && (actionCard.status ?? 'prepared') === 'prepared')
              }
            />
          )}
          {actionCard ? (
            <ActionCardView card={actionCard} onResolve={onResolveActionCard} />
          ) : prompt ? (
            <ChoiceCard
              prompt={prompt}
              interaction={prompt}
              askedBy={rich?.peer_agent_uid ? name : undefined}
              onAnswer={onAnswer}
              onComposeAnswer={onComposeAnswer}
              keyboardActive={keyboardActive}
              readOnlyReason={readOnlyReason}
            />
          ) : (
            message.text && (
              <div className={human ? 'pod-chat-human-text' : undefined}>
                <ChatMarkdown text={message.text} generated={message.authorType === 'agent'} />
              </div>
            )
          )}
          <MessageArtifacts conversationID={conversationID} message={message} />
          {linkedRuns.map(run => (
            <LinkedExecutionCard
              key={`${run.kind}:${run.id}`}
              conversationID={conversationID}
              run={run}
              showAgentName={showAgentOnRuns}
              isActive={isExecutionActive(activeInspector, run)}
              onOpenInspector={onOpenInspector}
            />
          ))}
          <MessageActions
            text={message.text}
            onQuote={onQuote}
            onSelectMessage={onSelectMessage}
            onEdit={onEdit}
            editDisabledReason={editDisabledReason}
            onRetry={onRetry}
            alwaysVisible={showActions || !!onRetry || backtrackActive}
          />
        </>
      )}
      {savedPages.map(page => (
        <Link key={page.id} className="pod-chat-page-pill pod-chat-saved-page" to={pageHref(page.id, page.title)}>
          <RiFileTextLine aria-hidden />
          {page.title || t('pod.content.untitled')}
        </Link>
      ))}
    </article>
  )
})

export function LiveMessage({
  stream,
  avatarURL,
  conversationID,
  linkedRuns,
  showAgentOnRuns = false,
  activeInspector,
  onOpenInspector
}: {
  stream: TimelineLiveStream
  avatarURL?: string | null
  conversationID: string
  linkedRuns: LinkedExecution[]
  showAgentOnRuns?: boolean
  activeInspector?: InspectorTarget | null
  onOpenInspector?: (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) => void
}) {
  const { t } = useTranslation()
  const label = useActivityLabel()
  const activeActivity = stream.activity?.state === 'active' ? stream.activity : undefined
  const rawSteps = activeActivity ? activitySteps(activeActivity, item => label(item, true)) : []
  const steps = filterPromotedExecutionSteps(rawSteps, linkedRuns)
  return (
    <article className="pod-chat-timeline-message pod-chat-agent-message" data-live-agent={stream.agentUID}>
      <MessageIdentity name={stream.agentName || t('pod.chat_timeline.agent')} avatarURL={avatarURL} />
      <CollapsedWorkView
        active
        startedAt={stream.startedAt}
        phaseLabel={!stream.thinkingSummary && activeActivity?.phase ? label(activeActivity.phase) : undefined}
        execution={{
          thinking_summary: stream.thinkingSummary,
          steps
        }}
      />
      {stream.text && <ChatMarkdown text={stream.text} generated streaming />}
      {linkedRuns.map(run => (
        <LinkedExecutionCard
          key={`${run.kind}:${run.id}`}
          conversationID={conversationID}
          run={run}
          showAgentName={showAgentOnRuns}
          isActive={isExecutionActive(activeInspector, run)}
          onOpenInspector={onOpenInspector}
        />
      ))}
    </article>
  )
}
