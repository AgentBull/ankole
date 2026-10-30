import { usePagesMetadata } from '../use-page-metadata'
import { Button, cn, useReducedMotion } from '@ankole/uikit'
import { RiArrowDownLine, RiFileTextLine, RiReplyLine } from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { useStickToBottom } from 'use-stick-to-bottom'
import { podLocation } from '../../common/browser-context'
import { ErrorBoundary } from '../../common/error-boundary'
import type { ConversationDetail, ConversationMessage, PodActivity, PodActivityItem } from '../api'
import { MessageArtifacts, SaveMessageButton } from '../message-artifacts'
import { OlderMessages, messageID, useChatReading, type useChatHistory } from '../chat-history'
import type { PageDetail } from '../content-api'
import { ChatModel, type ChatPresentation, type DisplayMessage } from '../state/chat'
import { ChatMarkdown } from './chat-markdown'
import { ChoiceCard, type ClarifyAnswer } from './choice-card'
import { CollapsedWorkView } from './collapsed-work-view'
import { LinkedExecutionCard } from './linked-execution-card'
import { MessageActions } from './message-actions'
import { humanizeToolName } from './tool-run-view'
import { TurnRail } from './turn-rail'
import { avatarInitials, ChatAvatar } from './chat-avatar'
import type { ExecutionStep, LinkedExecution, TimelineLiveStream, TimelineMessage } from './types'

type TimelineActions = {
  edit?(message: ConversationMessage): void
  editDisabledReason?: string
  regenerate?(message: ConversationMessage): void
}

type PendingQuestion = ConversationDetail['pendingInteractions'][number] & { state: 'pending' }

export function TurnTimeline({
  model,
  presentation,
  conversationID,
  history,
  messages,
  working,
  waiting,
  retryTime,
  activity,
  retryableMessageIDs,
  actions,
  onQuote,
  liveStreams,
  linkedRuns,
  pendingInteractions,
  latestInput,
  viewerUID,
  members,
  canAnswer,
  readOnlyReason,
  onAnswer,
  onComposeAnswer,
  onRefresh
}: {
  model: InstanceType<typeof ChatModel>
  presentation: ChatPresentation
  conversationID: string
  history: ReturnType<typeof useChatHistory>
  messages: DisplayMessage[]
  working: boolean
  waiting: boolean
  retryTime?: string
  activity?: PodActivity
  retryableMessageIDs: string[]
  actions?: TimelineActions
  onQuote?: (text: string, message: ConversationMessage) => void
  liveStreams: TimelineLiveStream[]
  linkedRuns: LinkedExecution[]
  pendingInteractions: ConversationDetail['pendingInteractions']
  latestInput?: ConversationDetail['latestInput']
  viewerUID: string
  members: ConversationDetail['conversation']['participants']
  canAnswer: (agentUID: string | null) => boolean
  readOnlyReason?: string
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  onRefresh?: () => void
}) {
  const { t } = useTranslation()
  const savedReading = useRef(model.reading.peek()[presentation])
  const reducedMotion = useReducedMotion()
  const stick = useStickToBottom({
    initial: savedReading.current?.atBottom === false ? false : 'instant',
    resize: reducedMotion ? 'instant' : 'smooth'
  })
  const { scrollRef, contentRef, isAtBottom, scrollToBottom } = stick
  const messageKeys = messages.map(messageID).join('|')
  useChatReading(model, presentation, stick, messageKeys, history.jumpToMatch)
  const committed = messages.filter(item => item.type === 'committed').map(item => item.message)
  const latestReply = committed.findLast(message => message.authorType === 'agent' && message.kind === 'message')
  const turns = timelineTurns(committed)
  const unloadedQuestions = unloadedPendingQuestions(pendingInteractions, committed)
  const canAnswerAgent = (uid: string | null) => !!onAnswer && canAnswer(uid)
  const lastChoice =
    committed.findLast(
      message =>
        (message as TimelineMessage).richContent?.clarify?.state === 'pending' &&
        canAnswerAgent(message.authorUID ?? null)
    )?.id ?? unloadedQuestions.findLast(question => canAnswerAgent(question.agentUID ?? null))?.messageID
  const activeStreams = uncommittedStreams(committed, liveStreams)
  const replySources = interleavedReplySources(committed)
  const executions = placeLinkedExecutions(committed, activeStreams, linkedRuns)
  const jumpToMessage = (id: string) => {
    const element = scrollRef.current?.querySelector<HTMLElement>(`[data-chat-message-id="${CSS.escape(id)}"]`)
    if (!element) return
    const range = document.createRange()
    range.selectNodeContents(element)
    history.jumpToMatch.current?.(range)
    return element
  }
  return (
    <div className="pod-chat-history pod-chat-timeline">
      <div
        ref={scrollRef}
        role="region"
        aria-label={t('pod.chat_history.label')}
        tabIndex={0}
        className="pod-chat-history-scroll">
        <div ref={contentRef} className="pod-chat-history-content">
          <OlderMessages history={history} scrollRef={scrollRef} />
          {messages.map((item, index) => (
            <div key={messageID(item)} data-chat-message-id={messageID(item)} tabIndex={-1}>
              <ErrorBoundary variant="inline" onReset={onRefresh} resetKeys={[messageID(item), item.message]}>
                {item.type === 'committed' ? (
                  <CommittedMessage
                    message={item.message as TimelineMessage}
                    conversationID={conversationID}
                    onEdit={
                      item.message.id === latestInput?.messageID && latestInput.authorUID === viewerUID && actions?.edit
                        ? () => actions.edit!(item.message)
                        : undefined
                    }
                    onRetry={
                      retryableMessageIDs.includes(item.message.id) && actions?.regenerate
                        ? () => actions.regenerate!(item.message)
                        : undefined
                    }
                    onQuote={onQuote ? text => onQuote(text, item.message) : undefined}
                    linkedRuns={executions.messages.get(item.message.id) ?? []}
                    replySource={replySources.get(item.message.id)}
                    onJumpToSource={id => jumpToMessage(id)?.focus({ preventScroll: true })}
                    onAnswer={canAnswerAgent(item.message.authorUID ?? null) ? onAnswer : undefined}
                    onComposeAnswer={canAnswerAgent(item.message.authorUID ?? null) ? onComposeAnswer : undefined}
                    readOnlyReason={readOnlyReason}
                    keyboardActive={item.message.id === lastChoice}
                    showActions={item.message.id === latestReply?.id}
                    editDisabledReason={actions?.editDisabledReason}
                    avatarURL={members.find(member => member.uid === item.message.authorUID)?.avatarURL}
                    own={item.message.authorType === 'human' && item.message.authorUID === viewerUID}
                    queued={item.queued}
                    continued={continuesPrevious(messages[index - 1], item, replySources.has(item.message.id))}
                  />
                ) : (
                  <article className="pod-chat-timeline-message pod-chat-human-message pod-chat-own-message pod-chat-message-pending">
                    <MessageIdentity name={t('pod.chat_timeline.you')} human quiet />
                    <div className="pod-chat-human-text">
                      <ChatMarkdown text={item.message.text ?? ''} />
                    </div>
                    <p role="status" className="pod-chat-message-state">
                      {t(item.message.state === 'failed' ? 'pod.chat.send_failed' : 'pod.chat.sending')}
                    </p>
                  </article>
                )}
              </ErrorBoundary>
            </div>
          ))}
          {activeStreams.map(stream => (
            <ErrorBoundary
              key={`${stream.agentUID}:${stream.responseID}`}
              variant="inline"
              resetKeys={[stream.responseID, stream.text]}>
              <LiveMessage
                stream={stream}
                conversationID={conversationID}
                linkedRuns={executions.streams.get(stream.agentUID) ?? []}
                avatarURL={members.find(member => member.uid === stream.agentUID)?.avatarURL}
              />
            </ErrorBoundary>
          ))}
          {unloadedQuestions.map(question => {
            const agent = members.find(member => member.uid === question.agentUID)
            return (
              <ErrorBoundary key={question.interaction_id} variant="inline" resetKeys={[question.interaction_id]}>
                <article
                  className="pod-chat-timeline-message pod-chat-agent-message"
                  data-pending-interaction={question.interaction_id}>
                  <MessageIdentity
                    name={agent?.displayName || t('pod.chat_timeline.agent')}
                    avatarURL={agent?.avatarURL}
                  />
                  <ChoiceCard
                    prompt={question}
                    interaction={question}
                    onAnswer={canAnswerAgent(question.agentUID ?? null) ? onAnswer : undefined}
                    onComposeAnswer={canAnswerAgent(question.agentUID ?? null) ? onComposeAnswer : undefined}
                    readOnlyReason={readOnlyReason}
                    keyboardActive={question.messageID === lastChoice}
                  />
                </article>
              </ErrorBoundary>
            )
          })}
          {!activeStreams.length && activity && <ActivityView activity={activity} />}
          {!activeStreams.length && !activity && working && (
            <p className="pod-chat-message-state" role="status">
              <span className="pod-chat-working-dot" aria-hidden />
              {waiting
                ? t('pod.chat_timeline.queued')
                : retryTime
                  ? t('pod.chat.retrying', { time: retryTime })
                  : t('pod.chat.replying')}
            </p>
          )}
        </div>
      </div>
      {presentation !== 'page' && <TurnRail turns={turns} scrollRef={scrollRef} onJump={jumpToMessage} />}
      {!isAtBottom && (
        <Button
          className="pod-chat-jump-latest"
          variant="ghost"
          size="sm"
          onClick={event => void scrollToBottom(reducedMotion || event.detail === 0 ? 'instant' : undefined)}>
          <RiArrowDownLine aria-hidden />
          {t('pod.chat.scroll_latest')}
          {working && <span className="pod-chat-working-dot" aria-hidden />}
        </Button>
      )}
    </div>
  )
}

/**
 * Who wrote a message. Your own messages and a message that continues the same author's last one keep the
 * name only for assistive technology, so the line shows only the time, on hover.
 */
function MessageIdentity({
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

// A conversation can span days, so a message from before today names its day as well as its time.
export function messageTime(value: string, locale: string, now = new Date()) {
  const date = new Date(value)
  const today = date.toDateString() === now.toDateString()
  return new Intl.DateTimeFormat(locale, {
    ...(today
      ? {}
      : { month: 'short', day: 'numeric', ...(date.getFullYear() === now.getFullYear() ? {} : { year: 'numeric' }) }),
    hour: '2-digit',
    minute: '2-digit'
  }).format(date)
}

/** Messages from one author within five minutes read as one block: the second drops its name and avatar. */
const CONTINUATION_MS = 5 * 60_000

function continuesPrevious(previous: DisplayMessage | undefined, current: DisplayMessage, hasReplySource: boolean) {
  if (!previous || previous.type !== 'committed' || current.type !== 'committed' || hasReplySource) return false
  const [a, b] = [previous.message, current.message]
  return (
    a.kind === 'message' &&
    b.kind === 'message' &&
    !!a.authorUID &&
    a.authorUID === b.authorUID &&
    Date.parse(b.createdAt) - Date.parse(a.createdAt) < CONTINUATION_MS
  )
}

function CommittedMessage({
  message,
  conversationID,
  onEdit,
  onRetry,
  onQuote,
  linkedRuns,
  replySource,
  onJumpToSource,
  onAnswer,
  onComposeAnswer,
  keyboardActive,
  showActions,
  editDisabledReason,
  avatarURL,
  own,
  queued,
  continued = false,
  readOnlyReason
}: {
  message: TimelineMessage
  conversationID: string
  onEdit?: () => void
  onRetry?: () => void
  onQuote?: (text: string) => void
  linkedRuns: LinkedExecution[]
  replySource?: Pick<ConversationMessage, 'id' | 'authorDisplayName' | 'text'>
  onJumpToSource(id: string): void
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  keyboardActive: boolean
  showActions: boolean
  editDisabledReason?: string
  avatarURL?: string | null
  own: boolean
  queued?: boolean
  continued?: boolean
  readOnlyReason?: string
}) {
  const { t, i18n } = useTranslation()
  const [saved, setSaved] = useState<PageDetail['page']>()
  const savedPages = usePagesMetadata([
    ...new Map([...message.savedPages, ...(saved ? [saved] : [])].map(page => [page.id, page])).values()
  ])
  const rich = message.richContent
  const human = message.authorType === 'human'
  const name = message.authorDisplayName
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
  const prompt = rich?.clarify
  return (
    <article
      className={cn(
        'pod-chat-timeline-message',
        human ? 'pod-chat-human-message' : 'pod-chat-agent-message',
        own && 'pod-chat-own-message',
        continued && 'pod-chat-continued-message'
      )}>
      <MessageIdentity
        name={name}
        human={human}
        archived={message.authorArchived}
        time={message.createdAt}
        avatarURL={avatarURL}
        quiet={own || continued}
      />
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
      {rich?.execution && <CollapsedWorkView execution={rich.execution} attention={prompt?.state === 'pending'} />}
      {prompt ? (
        <ChoiceCard
          prompt={prompt}
          interaction={prompt}
          onAnswer={onAnswer}
          onComposeAnswer={onComposeAnswer}
          keyboardActive={keyboardActive}
          readOnlyReason={readOnlyReason}
        />
      ) : (
        message.text && (
          <div className={human ? 'pod-chat-human-text' : undefined}>
            <ChatMarkdown text={message.text} />
          </div>
        )
      )}
      <MessageArtifacts conversationID={conversationID} message={message} />
      {linkedRuns.map(run => (
        <LinkedExecutionCard key={`${run.kind}:${run.id}`} conversationID={conversationID} run={run} />
      ))}
      <MessageActions
        text={message.text}
        onQuote={onQuote}
        onEdit={onEdit}
        editDisabledReason={editDisabledReason}
        onRetry={onRetry}
        alwaysVisible={showActions || !!onRetry}>
        {message.text.trim() && (
          <SaveMessageButton message={message} conversationID={conversationID} onSaved={setSaved} />
        )}
      </MessageActions>
      {savedPages.map(page => (
        <Link
          key={page.id}
          className="pod-chat-page-pill pod-chat-saved-page"
          to={podLocation(`/pages/${page.id}`).pathname}>
          <RiFileTextLine aria-hidden />
          {page.title || t('pod.content.untitled')}
        </Link>
      ))}
    </article>
  )
}

export function uncommittedStreams(messages: ConversationMessage[], streams: TimelineLiveStream[]) {
  return streams.filter(
    stream =>
      !messages.some(
        message => message.authorType === 'agent' && !!message.signalID && stream.signalIDs.includes(message.signalID)
      )
  )
}

export function timelineTurns(
  messages: Pick<ConversationMessage, 'id' | 'kind' | 'authorType' | 'text' | 'replyToMessageID' | 'richContent'>[]
) {
  const turns = new Map<string, { id: string; text: string; preview?: string }>()
  for (const message of messages) {
    if (message.kind !== 'message') continue
    if (message.authorType === 'human') turns.set(message.id, { id: message.id, text: message.text })
    else if (message.authorType === 'agent' && message.text && !message.richContent?.clarify) {
      const turn = message.replyToMessageID && turns.get(message.replyToMessageID)
      if (turn && !turn.preview) turn.preview = message.text
    }
  }
  return [...turns.values()]
}

export function interleavedReplySources(
  messages: Pick<
    ConversationMessage,
    'id' | 'kind' | 'authorType' | 'authorDisplayName' | 'text' | 'replyToMessageID'
  >[]
) {
  const humans = new Map<string, (typeof messages)[number]>()
  const sources = new Map<string, Pick<ConversationMessage, 'id' | 'authorDisplayName' | 'text'>>()
  let nearestHumanID: string | undefined
  for (const message of messages) {
    if (message.kind !== 'message') continue
    if (message.authorType === 'human') {
      humans.set(message.id, message)
      nearestHumanID = message.id
    } else if (message.authorType === 'agent' && message.replyToMessageID !== nearestHumanID) {
      const source = message.replyToMessageID && humans.get(message.replyToMessageID)
      if (source) sources.set(message.id, source)
    }
  }
  return sources
}

export function placeLinkedExecutions(
  messages: Pick<ConversationMessage, 'id' | 'kind' | 'authorType' | 'signalID' | 'richContent'>[],
  streams: TimelineLiveStream[],
  runs: LinkedExecution[]
) {
  const messageBySignal = new Map(
    messages
      .filter(
        message => message.authorType === 'agent' && (message.kind === 'message' || message.richContent?.execution)
      )
      .map(message => [message.signalID, message.id])
  )
  const streamBySignal = new Map(streams.flatMap(stream => stream.signalIDs.map(id => [id, stream.agentUID] as const)))
  const placement = {
    messages: new Map<string, LinkedExecution[]>(),
    streams: new Map<string, LinkedExecution[]>()
  }
  for (const run of runs) {
    const stream = run.sourceSignalID ? streamBySignal.get(run.sourceSignalID) : undefined
    const reply = run.sourceSignalID ? messageBySignal.get(run.sourceSignalID) : undefined
    const source =
      run.sourceMessageID &&
      messages.find(message => message.id === run.sourceMessageID && message.authorType === 'human')?.id
    const owner = stream ?? reply ?? source
    if (!owner) continue
    const destination = stream ? placement.streams : placement.messages
    destination.set(owner, [...(destination.get(owner) ?? []), run])
  }
  return placement
}

export function unloadedPendingQuestions(
  interactions: ConversationDetail['pendingInteractions'],
  messages: Pick<ConversationMessage, 'id'>[]
) {
  const loaded = new Set(messages.map(message => message.id))
  return interactions.filter(
    (question): question is PendingQuestion => question.state === 'pending' && !loaded.has(question.messageID)
  )
}

export function timelineEventLabel(
  message: Pick<TimelineMessage, 'richContent' | 'text'>,
  t: TFunction,
  locale: string
): string {
  const event = message.richContent?.event
  if (!event) return message.text
  const actor = event.actor_name
  switch (event.type) {
    case 'participants_added':
      return t('pod.chat_timeline.event_participants_added', {
        actor,
        targets: new Intl.ListFormat(locale, { type: 'conjunction' }).format(event.targets.map(target => target.name))
      })
    case 'participant_removed':
      if (event.targets.length === 1 && event.targets[0]!.uid === event.actor_uid) {
        return t('pod.chat_timeline.event_participant_left', { actor })
      }
      return t('pod.chat_timeline.event_participant_removed', {
        actor,
        targets: new Intl.ListFormat(locale, { type: 'conjunction' }).format(event.targets.map(target => target.name))
      })
    case 'title_renamed':
      return t('pod.chat_timeline.event_title_renamed', { actor, title: event.detail })
    case 'access_scope_changed': {
      if (event.detail !== 'participants' && event.detail !== 'anchor_page') return message.text
      return t('pod.chat_timeline.event_access_scope_changed', {
        actor,
        scope: t(`pod.chat_room.scope_${event.detail}`)
      })
    }
    default:
      return message.text
  }
}

export function activitySteps(activity: PodActivity, label: (item: PodActivityItem) => string): ExecutionStep[] {
  return activity.tools.map(item => ({
    id: item.operation_id,
    tool: item.operation_id,
    title: label(item),
    status: item.phase ?? 'running',
    duration_ms: item.duration_ms ?? undefined
  }))
}

function useActivityLabel() {
  const { t } = useTranslation()
  return (item: PodActivityItem, isTool = false) => {
    const fallback =
      isTool && !/^(?:call_|toolu_|[0-9a-f]{8}-)/i.test(item.operation_id)
        ? humanizeToolName(item.operation_id)
        : t('pod.chat.replying')
    return item.label_key?.startsWith('conversations.delivery.reply.activity.')
      ? t(item.label_key, { ...item.label_bindings, defaultValue: item.label || fallback })
      : item.label || fallback
  }
}

function ActivityView({ activity }: { activity: PodActivity }) {
  const label = useActivityLabel()
  return (
    <CollapsedWorkView
      active
      phaseLabel={activity.phase ? label(activity.phase) : undefined}
      execution={{
        steps: activitySteps(activity, item => label(item, true))
      }}
    />
  )
}

function LiveMessage({
  stream,
  avatarURL,
  conversationID,
  linkedRuns
}: {
  stream: TimelineLiveStream
  avatarURL?: string | null
  conversationID: string
  linkedRuns: LinkedExecution[]
}) {
  const { t } = useTranslation()
  const label = useActivityLabel()
  const activeActivity = stream.activity?.state === 'active' ? stream.activity : undefined
  return (
    <article className="pod-chat-timeline-message pod-chat-agent-message" data-live-agent={stream.agentUID}>
      <MessageIdentity name={stream.agentName || t('pod.chat_timeline.agent')} avatarURL={avatarURL} />
      <CollapsedWorkView
        active
        startedAt={stream.startedAt}
        phaseLabel={!stream.thinkingSummary && activeActivity?.phase ? label(activeActivity.phase) : undefined}
        execution={{
          thinking_summary: stream.thinkingSummary,
          steps: activeActivity ? activitySteps(activeActivity, item => label(item, true)) : []
        }}
      />
      {stream.text && <ChatMarkdown text={stream.text} className="pod-chat-live-text" />}
      {linkedRuns.map(run => (
        <LinkedExecutionCard key={`${run.kind}:${run.id}`} conversationID={conversationID} run={run} />
      ))}
    </article>
  )
}
