import { Button, cn, Spinner, toast, useReducedMotion } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  ArrowDownRegular,
  ArrowDownloadRegular,
  CheckboxCheckedRegular,
  CheckboxUncheckedRegular,
  CopyRegular,
  DismissRegular,
  ImageRegular
} from '@ankole/uikit/icons'
import { useQuery } from '@tanstack/react-query'
import {
  Fragment,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  type RefObject
} from 'react'
import { useTranslation } from 'react-i18next'
import { useStickToBottom } from 'use-stick-to-bottom'
import { ErrorBoundary } from '../../common/error-boundary'
import { agentsQuery, type ConversationDetail, type ConversationMessage, type PodActivity } from '../api'
import { messageID, OlderMessages, useChatReading, type useChatHistory } from '../chat-history'
import type { PanelInputEvent } from '../panel-motion'
import { ChatModel, type ChatPresentation, type ChatReadingPosition, type DisplayMessage } from '../state/chat'
import { ChatMarkdown } from './chat-markdown'
import { ChoiceCard, type ClarifyAnswer } from './choice-card'
import { ActivityView, WorkingLabel } from './collapsed-work-view'
import { downloadMarkdownString, selectionToMarkdown } from './export-markdown'
import { pairPeerExchanges } from './peer-exchange-card'
import type { ActionCardDecision } from './room-api'
import { captureSelectedMessages, type CaptureSelectedMessagesResult } from './select-screenshot'
import { SelectShareLightbox } from './select-share-lightbox'
import { MessageIdentity, MessageView, type InlineEditControls } from './timeline-message'
import {
  continuesPrevious,
  interleavedReplySources,
  placeDelegations,
  placeLinkedExecutions,
  resolveCommittedMessageEditState,
  timelineTurns,
  uncommittedStreams,
  unloadedPendingQuestions,
  type TimelineActions
} from './timeline-projections'
import { RevealInTimeline } from './timeline-scroll'
import { TurnRail } from './turn-rail'
import type { InspectorTarget, LinkedExecution, PlacedDelegation, TimelineLiveStream, TimelineMessage } from './types'
import { shouldYieldBacktrackToOverlay, useTimelineBacktrack } from './use-timeline-backtrack'

// Leaves room above the first unread message for the divider that introduces it.
const UNREAD_DIVIDER_OFFSET = 48
const EMPTY_LINKED_RUNS: LinkedExecution[] = []
const EMPTY_DELEGATIONS: PlacedDelegation[] = []

function useStableCallback<Args extends unknown[], Result>(fn: (...args: Args) => Result): (...args: Args) => Result {
  const ref = useRef(fn)
  useLayoutEffect(() => {
    ref.current = fn
  })
  return useCallback((...args: Args) => ref.current(...args), [])
}

export function TurnTimeline({
  model,
  presentation,
  conversationID,
  conversationTitle,
  detail,
  history,
  messages,
  working,
  waiting,
  retryTime,
  activity,
  retryableMessageIDs,
  editableMessageIDs,
  actions,
  inlineEdit,
  chatContainerRef,
  onReturnFocusToComposer,
  onQuote,
  onSaveAsSkill,
  onReply,
  liveStreams,
  linkedRuns,
  pendingInteractions,
  latestInput,
  viewerUID,
  members,
  canAnswer,
  readOnlyReason,
  onAnswer,
  onResolveActionCard,
  onComposeAnswer,
  onRefresh,
  unreadMessageID,
  showAgentOnRuns = false,
  activeInspector,
  onOpenInspector
}: {
  model: InstanceType<typeof ChatModel>
  presentation: ChatPresentation
  conversationID: string
  conversationTitle?: string
  detail?: ConversationDetail
  history: ReturnType<typeof useChatHistory>
  messages: DisplayMessage[]
  working: boolean
  waiting: boolean
  retryTime?: string
  activity?: PodActivity
  retryableMessageIDs: string[]
  editableMessageIDs?: string[]
  actions?: TimelineActions
  inlineEdit?: InlineEditControls
  chatContainerRef?: RefObject<HTMLElement | null>
  onReturnFocusToComposer?: () => void
  onQuote?: (text: string, message: ConversationMessage) => void
  onSaveAsSkill?: () => void
  /** Receives the follow-up text of a `ui` block's reply button. */
  onReply?: (text: string) => void
  liveStreams: TimelineLiveStream[]
  linkedRuns: LinkedExecution[]
  pendingInteractions: ConversationDetail['pendingInteractions']
  latestInput?: ConversationDetail['latestInput']
  viewerUID: string
  members: ConversationDetail['conversation']['participants']
  canAnswer: (agentUID: string | null) => boolean
  readOnlyReason?: string
  onAnswer?: (interactionID: string, answer: ClarifyAnswer) => Promise<unknown>
  onResolveActionCard?: (cardID: string, decision: ActionCardDecision) => Promise<unknown>
  onComposeAnswer?: (interactionID: string, text: string) => void
  onRefresh?: () => void
  /** The first message the viewer had not read on entering; the timeline opens there under a divider. */
  unreadMessageID?: string
  showAgentOnRuns?: boolean
  activeInspector?: InspectorTarget | null
  onOpenInspector?: (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) => void
}) {
  useSignals()
  const { t } = useTranslation()
  // A position remembered in this session wins; otherwise the timeline opens with the new-messages divider in view.
  const savedReading = useRef<ChatReadingPosition | undefined>(
    model.reading.peek()[presentation] ??
      (unreadMessageID ? { atBottom: false, messageID: unreadMessageID, offset: UNREAD_DIVIDER_OFFSET } : undefined)
  )
  const reducedMotion = useReducedMotion()
  const [shareOpen, setShareOpen] = useState(false)
  const [shareLoading, setShareLoading] = useState(false)
  const [shareError, setShareError] = useState<string | null>(null)
  const [shareResult, setShareResult] = useState<CaptureSelectedMessagesResult | null>(null)
  const holdScrollRef = useRef(false)
  const activeEditTarget = model.editing.value
  const activeInlineEditID = activeEditTarget?.kind === 'last' ? activeEditTarget.messageID : undefined
  const holdScroll = Boolean(activeInlineEditID || model.backtrackMessageID.value)
  useLayoutEffect(() => {
    holdScrollRef.current = holdScroll
  }, [holdScroll])
  const stick = useStickToBottom({
    initial: savedReading.current?.atBottom === false ? false : 'instant',
    resize: reducedMotion ? 'instant' : 'smooth',
    targetScrollTop: (target, { scrollElement }) => (holdScrollRef.current ? scrollElement.scrollTop : target)
  })
  const { scrollRef, contentRef, isAtBottom, scrollToBottom } = stick
  const messageKeys = messages.map(messageID).join('|')
  useChatReading(model, presentation, stick, messageKeys, history.jumpToMatch, savedReading.current)
  const committed = useMemo(
    () => messages.filter(item => item.type === 'committed').map(item => item.message),
    [messages]
  )
  const selectableMessages = useMemo(() => committed.filter(msg => msg.kind !== 'notice'), [committed])
  const selecting = model.selectingMessages.value
  const selectedIDSet = new Set(model.selectedMessageIDs.value)
  const selectedMessages = selectableMessages.filter(msg => selectedIDSet.has(msg.id))
  const timelineRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!selecting) return
    const container = chatContainerRef?.current ?? timelineRef.current
    if (!container) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (shouldYieldBacktrackToOverlay(event.target, container)) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        model.clearMessageSelection()
      }
    }
    container.addEventListener('keydown', onKeyDown)
    return () => container.removeEventListener('keydown', onKeyDown)
  }, [selecting, chatContainerRef, model])

  const openShareCard = async () => {
    const container = contentRef.current
    if (!container || selectedMessages.length === 0) return
    setShareOpen(true)
    setShareLoading(true)
    setShareError(null)
    setShareResult(null)
    try {
      const captured = await captureSelectedMessages({
        container,
        messageIds: selectedMessages.map(msg => msg.id),
        title: conversationTitle
      })
      setShareResult(captured)
    } catch (err) {
      setShareError(err instanceof Error ? err.message : t('pod.chat.copy_failed'))
    } finally {
      setShareLoading(false)
    }
  }
  const latestReply = useMemo(
    () => committed.findLast(message => message.authorType === 'agent' && message.kind === 'message'),
    [committed]
  )
  const turns = useMemo(() => timelineTurns(committed), [committed])
  const unloadedQuestions = unloadedPendingQuestions(pendingInteractions, committed)
  const canAnswerAgent = (uid: string | null) => !!onAnswer && canAnswer(uid)
  const directory = useQuery(agentsQuery)
  const peerNames = new Map((directory.data?.agents ?? []).map(agent => [agent.uid, agent.displayName]))
  const lastChoice =
    committed.findLast(
      message =>
        (message as TimelineMessage).richContent?.clarify?.state === 'pending' &&
        canAnswerAgent(message.authorUID ?? null)
    )?.id ?? unloadedQuestions.findLast(question => canAnswerAgent(question.agentUID ?? null))?.messageID
  const activeStreams = uncommittedStreams(committed, liveStreams)
  const replySources = useMemo(() => interleavedReplySources(committed), [committed])
  // A colleague's reply joins the delegation row it answers instead of appearing as a second card.
  const peerExchanges = useMemo(() => pairPeerExchanges(committed as TimelineMessage[]), [committed])
  const committedByID = useMemo(
    () => new Map(committed.map(message => [message.id, message as TimelineMessage])),
    [committed]
  )
  const streamRoutingKey = activeStreams.map(stream => `${stream.agentUID}:${stream.signalIDs.join(',')}`).join('|')
  const executions = useMemo(
    () => placeLinkedExecutions(committed, activeStreams, linkedRuns),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- placeLinkedExecutions reads only agentUID and signalIDs on streams
    [committed, streamRoutingKey, linkedRuns]
  )
  // A delegation stands under the reply of the turn that sent it instead of in a row of its own before that reply.
  const delegations = useMemo(
    () => {
      const placement = placeDelegations(committed as TimelineMessage[], activeStreams)
      const cards = (owners: Map<string, string[]>) =>
        new Map(
          [...owners].map(([owner, ids]) => [
            owner,
            ids.flatMap((id): PlacedDelegation[] => {
              const request = committedByID.get(id)
              return request
                ? [
                    {
                      request,
                      reply: committedByID.get(peerExchanges.replies.get(id) ?? ''),
                      live: peerExchanges.latest.has(id)
                    }
                  ]
                : []
            })
          ])
        )
      return { placed: placement.placed, messages: cards(placement.messages), streams: cards(placement.streams) }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- placeDelegations reads only agentUID and signalIDs on streams
    [committed, streamRoutingKey, committedByID, peerExchanges]
  )
  const retryableSet = new Set(retryableMessageIDs)
  const memberAvatarByUID = new Map(members.map(member => [member.uid, member.avatarURL]))
  const revealElement = (element: Element) => {
    const range = document.createRange()
    range.selectNodeContents(element)
    history.jumpToMatch.current?.(range)
  }
  const jumpToMessage = (id: string) => {
    const element = scrollRef.current?.querySelector<HTMLElement>(`[data-chat-message-id="${CSS.escape(id)}"]`)
    if (!element) return
    revealElement(element)
    return element
  }
  const stableJumpToSource = useStableCallback((sourceID: string) => {
    jumpToMessage(sourceID)?.focus({ preventScroll: true })
  })
  const stableEditMessage = useStableCallback((message: ConversationMessage) => actions?.edit?.(message))
  const stableRegenerateMessage = useStableCallback((message: ConversationMessage) => actions?.regenerate?.(message))
  const stableQuoteMessage = useStableCallback((text: string, message: ConversationMessage) => onQuote?.(text, message))
  const stableSaveAsSkill = useStableCallback(() => onSaveAsSkill?.())
  const stableReply = useStableCallback((text: string) => onReply?.(text))
  const stableSelectMessageID = useCallback((id: string) => model.startSelectingMessages(id), [model])
  const stableOpenInspector = useStableCallback(
    (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) =>
      onOpenInspector?.(target, trigger, event)
  )
  const stableAnswer = useStableCallback((interactionID: string, answer: ClarifyAnswer) =>
    onAnswer ? onAnswer(interactionID, answer) : Promise.resolve()
  )
  const stableResolveActionCard = useStableCallback((cardID: string, decision: ActionCardDecision) =>
    onResolveActionCard ? onResolveActionCard(cardID, decision) : Promise.resolve()
  )
  const stableComposeAnswer = useStableCallback((interactionID: string, text: string) =>
    onComposeAnswer?.(interactionID, text)
  )
  const backtrackID = useTimelineBacktrack({
    containerRef: chatContainerRef,
    fallbackRef: timelineRef,
    scrollRef,
    model,
    editableMessageIDs,
    committedByID,
    onEdit: actions?.edit,
    onReturnFocusToComposer
  })
  /**
   * Wraps one timeline row. Live replies and committed messages share this wrapper and `MessageView`, so a committed
   * reply that takes over its live reply's key (`ChatModel.messageKey`) reuses the same tree.
   */
  const row = (
    key: string,
    id: string | undefined,
    author: string | undefined,
    resetKeys: unknown[],
    content: ReactNode
  ) => {
    const selectable = author !== undefined
    const isSelected = selectable && !!id && selectedIDSet.has(id)
    return (
      <Fragment key={key}>
        {id !== undefined && id === unreadMessageID && (
          <div className="pod-chat-unread-divider" role="separator" aria-label={t('pod.chat_timeline.new_messages')}>
            {t('pod.chat_timeline.new_messages')}
          </div>
        )}
        <div
          data-chat-message-id={id}
          tabIndex={-1}
          className={cn(
            selecting &&
              selectable &&
              'relative flex items-start gap-2 rounded-control px-1.5 py-0.5 transition-colors',
            isSelected && 'bg-accent/55 ring-1 ring-border'
          )}>
          {selecting && selectable && id && (
            <button
              type="button"
              data-select-ignore=""
              role="checkbox"
              aria-checked={isSelected}
              aria-label={t('pod.chat_timeline.select_message_item', {
                defaultValue: 'Select message from {$author}',
                author
              })}
              onClick={() => model.toggleSelectedMessage(id)}
              className="mt-2.5 inline-flex size-5 shrink-0 items-center justify-center rounded text-fg-secondary hover:text-foreground">
              {isSelected ? (
                <CheckboxCheckedRegular className="size-4 text-primary" aria-hidden />
              ) : (
                <CheckboxUncheckedRegular className="size-4" aria-hidden />
              )}
            </button>
          )}
          <div className={selecting && selectable ? 'min-w-0 flex-1' : undefined}>
            <ErrorBoundary variant="inline" onReset={onRefresh} resetKeys={resetKeys}>
              {content}
            </ErrorBoundary>
          </div>
        </div>
      </Fragment>
    )
  }
  return (
    <RevealInTimeline.Provider value={revealElement}>
      <div ref={timelineRef} className="pod-chat-history pod-chat-timeline">
        <div
          ref={scrollRef}
          role="region"
          aria-label={t('pod.chat_history.label')}
          tabIndex={0}
          className="pod-chat-history-scroll">
          <div ref={contentRef} className="pod-chat-history-content">
            <OlderMessages history={history} scrollRef={scrollRef} />
            {[
              ...messages.map((item, index) => {
                const id = messageID(item)
                if (
                  item.type === 'committed' &&
                  (peerExchanges.paired.has(item.message.id) || delegations.placed.has(item.message.id))
                ) {
                  return null
                }
                // A reply that carries its turn's delegation follows the row before that delegation.
                let before = index - 1
                while (before >= 0) {
                  const earlier = messages[before]
                  if (earlier.type !== 'committed' || !delegations.placed.has(earlier.message.id)) break
                  before -= 1
                }
                if (item.type !== 'committed') {
                  return row(
                    id,
                    id,
                    undefined,
                    [id, item.message],
                    <article className="pod-chat-timeline-message pod-chat-human-message pod-chat-own-message pod-chat-message-pending">
                      <MessageIdentity name={t('pod.chat_timeline.you')} quiet />
                      <div className="pod-chat-human-text">
                        <ChatMarkdown text={item.message.text ?? ''} />
                      </div>
                      <p role="status" className="pod-chat-message-state">
                        {t(item.message.state === 'failed' ? 'pod.chat.send_failed' : 'pod.chat.sending')}
                      </p>
                    </article>
                  )
                }
                const editState = resolveCommittedMessageEditState({
                  message: item.message,
                  actions,
                  latestInput,
                  viewerUID,
                  activeEditTarget,
                  hasInlineEditContext: Boolean(detail && inlineEdit),
                  backtrackID
                })
                const retryable = retryableSet.has(item.message.id)
                const allowAnswer = canAnswerAgent(item.message.authorUID ?? null)
                const selectable = item.message.kind !== 'notice'
                return row(
                  model.messageKey(id),
                  id,
                  selectable ? item.message.authorDisplayName : undefined,
                  [id, item.message],
                  <MessageView
                    model={model}
                    detail={editState.editingInline ? detail : undefined}
                    message={item.message as TimelineMessage}
                    conversationID={conversationID}
                    peerReply={committedByID.get(peerExchanges.replies.get(item.message.id) ?? '')}
                    peerLive={peerExchanges.latest.has(item.message.id)}
                    inlineEdit={editState.editingInline ? inlineEdit : undefined}
                    canEdit={editState.canEdit}
                    editDisabledReason={editState.editDisabledReason}
                    editingInline={editState.editingInline}
                    backtrackActive={editState.backtrackActive}
                    retryable={retryable}
                    onEditMessage={actions?.edit ? stableEditMessage : undefined}
                    onRegenerateMessage={retryable && actions?.regenerate ? stableRegenerateMessage : undefined}
                    onQuoteMessage={onQuote ? stableQuoteMessage : undefined}
                    onSaveAsSkill={onSaveAsSkill ? stableSaveAsSkill : undefined}
                    onReply={onReply ? stableReply : undefined}
                    onSelectMessageID={selectable ? stableSelectMessageID : undefined}
                    linkedRuns={executions.messages.get(item.message.id) ?? EMPTY_LINKED_RUNS}
                    delegations={delegations.messages.get(item.message.id) ?? EMPTY_DELEGATIONS}
                    showAgentOnRuns={showAgentOnRuns}
                    activeInspector={activeInspector}
                    onOpenInspector={onOpenInspector ? stableOpenInspector : undefined}
                    replySource={replySources.get(item.message.id)}
                    onJumpToSource={stableJumpToSource}
                    onAnswer={allowAnswer && onAnswer ? stableAnswer : undefined}
                    onResolveActionCard={onResolveActionCard ? stableResolveActionCard : undefined}
                    onComposeAnswer={allowAnswer && onComposeAnswer ? stableComposeAnswer : undefined}
                    readOnlyReason={readOnlyReason}
                    keyboardActive={item.message.id === lastChoice}
                    showActions={item.message.id === latestReply?.id}
                    avatarURL={memberAvatarByUID.get(item.message.authorUID ?? '')}
                    own={item.message.authorType === 'human' && item.message.authorUID === viewerUID}
                    queued={item.queued}
                    continued={
                      id !== unreadMessageID &&
                      continuesPrevious(messages[before], item, replySources.has(item.message.id))
                    }
                  />
                )
              }),
              ...activeStreams.map(stream =>
                row(
                  model.liveReplyKey(stream.agentUID),
                  undefined,
                  undefined,
                  [stream.responseID, stream.text],
                  <MessageView
                    model={model}
                    live={stream}
                    conversationID={conversationID}
                    linkedRuns={executions.streams.get(stream.agentUID) ?? EMPTY_LINKED_RUNS}
                    delegations={delegations.streams.get(stream.agentUID) ?? EMPTY_DELEGATIONS}
                    showAgentOnRuns={showAgentOnRuns}
                    activeInspector={activeInspector}
                    onOpenInspector={onOpenInspector ? stableOpenInspector : undefined}
                    onReply={onReply ? stableReply : undefined}
                    onJumpToSource={stableJumpToSource}
                    keyboardActive={false}
                    showActions={false}
                    avatarURL={memberAvatarByUID.get(stream.agentUID)}
                    own={false}
                  />
                )
              )
            ]}
            {unloadedQuestions.map(question => {
              const agent = members.find(member => member.uid === question.agentUID)
              const asker = agent?.displayName ?? peerNames.get(question.agentUID ?? '') ?? `@${question.agentUID}`
              return (
                <ErrorBoundary key={question.interaction_id} variant="inline" resetKeys={[question.interaction_id]}>
                  <article
                    className="pod-chat-timeline-message pod-chat-agent-message"
                    data-pending-interaction={question.interaction_id}>
                    <MessageIdentity name={asker} avatarURL={agent?.avatarURL} agent quiet={!agent} />
                    <ChoiceCard
                      prompt={question}
                      interaction={question}
                      askedBy={agent ? undefined : asker}
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
                <Spinner aria-hidden className="pod-chat-working-spinner" />
                <WorkingLabel
                  text={
                    waiting
                      ? t('pod.chat_timeline.queued')
                      : retryTime
                        ? t('pod.chat.retrying', { time: retryTime })
                        : t('pod.chat.replying')
                  }
                />
              </p>
            )}
          </div>
        </div>
        {presentation !== 'page' && <TurnRail turns={turns} scrollRef={scrollRef} onJump={jumpToMessage} />}
        {selecting && (
          <div
            role="toolbar"
            data-testid="chat-selection-toolbar"
            aria-label={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
            className="ceramic sticky bottom-2 z-20 mx-auto my-2 flex flex-wrap items-center gap-1.5 px-3 py-1.5 text-xs">
            <span className="px-1 font-medium text-foreground">
              {t('pod.chat_timeline.selected_count', {
                defaultValue: '{$count} selected',
                count: selectedMessages.length
              })}
            </span>
            <Button
              variant="ghost"
              size="xs"
              onClick={() =>
                model.setSelectedMessages(
                  selectedMessages.length === selectableMessages.length ? [] : selectableMessages.map(msg => msg.id)
                )
              }>
              {selectedMessages.length === selectableMessages.length && selectableMessages.length > 0
                ? t('pod.chat_timeline.clear_selection', { defaultValue: 'Clear' })
                : t('pod.chat_timeline.select_all', { defaultValue: 'Select all' })}
            </Button>
            <Button
              variant="outline"
              size="xs"
              disabled={selectedMessages.length === 0}
              onClick={() => void openShareCard()}>
              <ImageRegular aria-hidden />
              {t('pod.chat_timeline.share_image', { defaultValue: 'Share image' })}
            </Button>
            <Button
              variant="ghost"
              size="xs"
              disabled={selectedMessages.length === 0}
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(
                    selectionToMarkdown(selectedMessages, { title: conversationTitle })
                  )
                  toast.success(t('pod.chat_timeline.copied'))
                } catch {
                  toast.error(t('pod.chat.copy_failed'))
                }
              }}>
              <CopyRegular aria-hidden />
              {t('pod.chat_timeline.copy_markdown', { defaultValue: 'Copy Markdown' })}
            </Button>
            <Button
              variant="ghost"
              size="xs"
              disabled={selectedMessages.length === 0}
              onClick={() =>
                downloadMarkdownString(
                  selectionToMarkdown(selectedMessages, { title: conversationTitle }),
                  conversationTitle || 'conversation-excerpt'
                )
              }>
              <ArrowDownloadRegular aria-hidden />
              {t('pod.chat_timeline.download_markdown', { defaultValue: 'Download .md' })}
            </Button>
            <Button
              variant="ghost"
              size="icon-xs"
              title={t('common.close')}
              aria-label={t('common.close')}
              onClick={() => model.clearMessageSelection()}>
              <DismissRegular aria-hidden />
            </Button>
          </div>
        )}
        {!isAtBottom && !selecting && (
          <Button
            className="pod-chat-jump-latest"
            variant="ghost"
            size="sm"
            onClick={event => void scrollToBottom(reducedMotion || event.detail === 0 ? 'instant' : undefined)}>
            <ArrowDownRegular aria-hidden />
            {t('pod.chat.scroll_latest')}
            {working && <Spinner aria-hidden className="pod-chat-working-spinner" />}
          </Button>
        )}
        {shareOpen && (
          <SelectShareLightbox
            open={shareOpen}
            onOpenChange={setShareOpen}
            loading={shareLoading}
            error={shareError}
            result={shareResult}
            messages={selectedMessages}
            title={conversationTitle}
          />
        )}
      </div>
    </RevealInTimeline.Provider>
  )
}
