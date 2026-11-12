import { cn } from '@ankole/uikit'
import { memo } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail, ConversationMessage } from '../api'
import type { ChatCommands } from '../chat-commands'
import { MessageArtifacts, PageReferenceCard } from '../message-artifacts'
import type { PanelInputEvent } from '../panel-motion'
import { ChatModel } from '../state/chat'
import { usePagesMetadata } from '../use-page-metadata'
import { ActionCardView } from './action-card-view'
import { ChatAvatar } from './chat-avatar'
import { ChatMarkdown } from './chat-markdown'
import { ChoiceCard, type ClarifyAnswer } from './choice-card'
import { activitySteps, CollapsedWorkView, useActivityLabel } from './collapsed-work-view'
import { ConnectorAuthCardView } from './connector-auth-card-view'
import { InlineMessageEditor } from './inline-message-editor'
import { LinkedExecutionCard } from './linked-execution-card'
import { MessageActions } from './message-actions'
import { PageAccessCardView } from './page-access-card-view'
import { PeerExchangeCard } from './peer-exchange-card'
import type { ActionCardDecision } from './room-api'
import {
  filterPromotedExecutionSteps,
  isExecutionActive,
  isPeerActive,
  messageTime,
  timelineEventLabel
} from './timeline-projections'
import type {
  ExecutionSummary,
  InspectorTarget,
  LinkedExecution,
  PlacedDelegation,
  TimelineLiveStream,
  TimelineMessage
} from './types'

const NO_SAVED_PAGES: TimelineMessage['savedPages'] = []
const NO_DELEGATIONS: PlacedDelegation[] = []

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
 * Who wrote a message: a 32px round avatar, which Agents and people share, and the name. An Agent without an uploaded
 * avatar shows the bot mark instead of initials. Your own messages and a message that continues the same author's
 * last one keep the name only for assistive technology. The message states its time in its action row, not on this
 * line.
 */
export function MessageIdentity({
  name,
  archived = false,
  avatarURL,
  agent = false,
  quiet = false
}: {
  name: string
  archived?: boolean
  avatarURL?: string | null
  agent?: boolean
  quiet?: boolean
}) {
  const { t } = useTranslation()
  return (
    <header className="pod-chat-message-identity" data-quiet={quiet || undefined}>
      {!quiet && (
        <ChatAvatar name={name} src={avatarURL} agent={agent} size="default" className="pod-chat-message-avatar" />
      )}
      <strong className={quiet ? 'sr-only' : undefined}>{name}</strong>
      {archived && <span className="pod-chat-archived">{t('pod.chat_timeline.archived')}</span>}
    </header>
  )
}

/**
 * Renders a timeline message. An Agent reply renders here while it streams too, with `live` in place of
 * `message`, so that the committed message that replaces it reuses the same tree and its content keeps its state.
 */
export const MessageView = memo(function MessageView({
  model,
  detail,
  message,
  live,
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
  onSaveAsSkill,
  onReply,
  onSelectMessageID,
  linkedRuns,
  delegations = NO_DELEGATIONS,
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
  message?: TimelineMessage
  live?: TimelineLiveStream
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
  onSaveAsSkill?: () => void
  onReply?: (text: string) => void
  onSelectMessageID?: (messageID: string) => void
  linkedRuns: LinkedExecution[]
  /** The delegations this reply's turn sent, shown under its text. */
  delegations?: PlacedDelegation[]
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
  const label = useActivityLabel()
  const savedPages = usePagesMetadata(message?.savedPages ?? NO_SAVED_PAGES)
  const rich = message?.richContent
  const human = message?.authorType === 'human'
  const agent = !!live || message?.authorType === 'agent'
  const name = message ? message.authorDisplayName : live?.agentName || t('pod.chat_timeline.agent')
  const onRetry = message && retryable && onRegenerateMessage ? () => onRegenerateMessage(message) : undefined
  const onEdit = message && canEdit && onEditMessage ? () => onEditMessage(message) : undefined
  const onQuote = message && onQuoteMessage ? (text: string) => onQuoteMessage(text, message) : undefined
  const onSelectMessage = message && onSelectMessageID ? () => onSelectMessageID(message.id) : undefined

  if (message?.kind === 'notice' && !rich?.execution) {
    const label = timelineEventLabel(message, t, i18n.language)
    return (
      <div className="pod-chat-timeline-event">
        <ChatAvatar name={name} src={avatarURL} agent={agent} size="xs" className="pod-chat-notice-avatar" />
        <p title={label}>{label}</p>
        <time dateTime={message.createdAt} title={new Date(message.createdAt).toLocaleString(i18n.language)}>
          {messageTime(message.createdAt, i18n.language)}
        </time>
        {onRetry && <MessageActions text="" onRetry={onRetry} alwaysVisible />}
      </div>
    )
  }
  if (message && rich?.agent_peer_outbound) {
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
  const connectorAuth = rich?.connector_auth
  const accessBlocked = rich?.access_blocked
  const actionCard = rich?.action_card
  const activity = live?.activity?.state === 'active' ? live.activity : undefined
  const execution: ExecutionSummary | undefined = live
    ? {
        thinking_summary: live.thinkingSummary,
        steps: filterPromotedExecutionSteps(
          activity ? activitySteps(activity, item => label(item, true)) : [],
          linkedRuns
        )
      }
    : rich?.execution && { ...rich.execution, steps: filterPromotedExecutionSteps(rich.execution.steps, linkedRuns) }
  const text = message ? message.text : live?.text
  return (
    <article
      data-live-agent={live?.agentUID}
      data-backtrack-active={backtrackActive || undefined}
      className={cn(
        'pod-chat-timeline-message',
        human ? 'pod-chat-human-message' : 'pod-chat-agent-message',
        own && 'pod-chat-own-message',
        backtrackActive && !editingInline && 'pod-chat-backtrack-active'
      )}>
      <MessageIdentity
        name={name}
        archived={message?.authorArchived}
        avatarURL={avatarURL}
        agent={agent}
        quiet={!!message && (own || continued || !!rich?.peer_agent_uid)}
      />
      {message && editingInline && detail && inlineEdit ? (
        <InlineMessageEditor model={model} message={message} detail={detail} {...inlineEdit} />
      ) : (
        <>
          {backtrackActive && <span className="pod-chat-backtrack-pill">{t('pod.chat.backtrack_hint')}</span>}
          {queued && <span className="pod-chat-queued-badge">{t('pod.chat_timeline.queued')}</span>}
          {replySource && (
            <button type="button" className="pod-chat-reply-source" onClick={() => onJumpToSource(replySource.id)}>
              <span>
                {t('pod.chat_timeline.reply_source', {
                  name: replySource.authorDisplayName,
                  text: replySource.text.replace(/\s+/g, ' ').trim().slice(0, 160) || t('pod.content.attachment')
                })}
              </span>
            </button>
          )}
          {message?.links
            .filter(link => link.quote)
            .map(link => (
              <blockquote key={link.id} className="pod-chat-quoted-message">
                {link.quote}
              </blockquote>
            ))}
          {execution && (
            <CollapsedWorkView
              execution={execution}
              active={!!live}
              startedAt={live?.startedAt}
              phaseLabel={live && !live.thinkingSummary && activity?.phase ? label(activity.phase) : undefined}
              attention={
                prompt?.state === 'pending' ||
                connectorAuth?.state === 'pending' ||
                accessBlocked?.state === 'pending' ||
                (!!actionCard && (actionCard.status ?? 'prepared') === 'prepared')
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
            <>
              {text && (!connectorAuth || text !== `Connect ${connectorAuth.display_name} to continue.`) && (
                <div className={human ? 'pod-chat-human-text' : undefined}>
                  <ChatMarkdown text={text} generated={agent} streaming={!!live} onReply={onReply} />
                </div>
              )}
              {connectorAuth && <ConnectorAuthCardView prompt={connectorAuth} />}
              {accessBlocked && <PageAccessCardView conversationID={conversationID} prompt={accessBlocked} />}
            </>
          )}
          {message && <MessageArtifacts conversationID={conversationID} message={message} />}
          {delegations.map(({ request, reply, live: followsColleague }) => {
            const peer = request.richContent?.agent_peer_outbound
            return (
              peer && (
                <PeerExchangeCard
                  key={request.id}
                  conversationID={conversationID}
                  peer={peer}
                  request={request}
                  reply={reply}
                  live={followsColleague}
                  isActive={isPeerActive(activeInspector, peer.exchange_id)}
                  onOpenInspector={onOpenInspector ? (target, trigger) => onOpenInspector(target, trigger) : undefined}
                />
              )
            )
          })}
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
          {message && (
            <MessageActions
              text={message.text}
              time={message.createdAt}
              timeFirst={own}
              onQuote={onQuote}
              onSaveAsSkill={
                !human && message.kind === 'message' && !actionCard && !prompt && !connectorAuth && !accessBlocked
                  ? onSaveAsSkill
                  : undefined
              }
              onSelectMessage={onSelectMessage}
              onEdit={onEdit}
              editDisabledReason={editDisabledReason}
              onRetry={onRetry}
              alwaysVisible={showActions || !!onRetry || backtrackActive}
            />
          )}
        </>
      )}
      {savedPages.length > 0 && (
        <div className="pod-chat-saved-pages">
          {savedPages.map(page => (
            <PageReferenceCard key={page.id} id={page.id} title={page.title || t('pod.content.untitled')} />
          ))}
        </div>
      )}
    </article>
  )
})
