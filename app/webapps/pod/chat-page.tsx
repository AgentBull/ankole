import { podLocation, podRouteID } from '../common/browser-context'
import {
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogContent,
  DialogTitle,
  DialogFooter,
  useIsMobile
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useCallback, useEffect, useEffectEvent, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { ErrorBoundary } from '../common/error-boundary'
import { requestErrorMessage } from '../common/request-errors'
import {
  chatError,
  agentsQuery,
  conversationNotFound,
  conversationQuery,
  podKeys,
  type ConversationDetail
} from './api'
import { ChatModel, mergeMessages } from './state/chat'
import { LocalChatDrafts, UnconfirmedChats, useChatDraft, useChatDrafts } from './chat-drafts'
import { findMessageStep, firstUnreadMessageID, useChatHistory, type ChatEntry } from './chat-history'
import type { PodCommandNavigationState } from './command-menu'
import { editingSnapshot, useChatCommands, type ChatCommands } from './chat-commands'
import { ChatAttachmentDrafts } from './chat-attachments'
import { useConversationEvents } from './use-conversation-events'
import { refreshConversationDetail } from './query-cache'
import { deleteConversation } from './api/generated/sdk.gen'
import { Composer } from './chat/composer'
import { TurnTimeline, isExecutionActive, isPeerActive } from './chat/turn-timeline'
import { ChatHomeView, ChatHomeToolbar } from './chat/chat-home-view'
import { RoomHeader } from './chat/room-header'
import { SharePopover } from './chat/share-popover'
import { NewGroupDialog } from './chat/new-group-dialog'
import { ChatSummaryPanel } from './chat/chat-summary-panel'
import { ExecutionInspectorPanel } from './chat/execution-inspector-panel'
import { isLiveExecutionStatus } from './chat/execution-status'
import type { InspectorTarget } from './chat/types'
import { SessionFindBar } from './chat/session-find-bar'
import { QueuedStrip } from './chat/queued-strip'
import { useRoomActions } from './chat/room-api'
import { PodPanelPresence, usePanelMotion, type PanelInputEvent } from './panel-motion'
import './chat.css'

export function ChatRoute() {
  useSignals()
  const drafts = useChatDrafts()
  const { conversationID } = useParams({ strict: false })
  const location = useLocation()
  const fullID = podRouteID(conversationID)
  const locationKey = (location.state as { __TSR_key?: string } | null)?.__TSR_key ?? location.href
  return (
    <ChatPage
      key={fullID ?? conversationID ?? `${locationKey}:${drafts.newChatVersion.value}`}
      conversationID={fullID ?? conversationID}
    />
  )
}

export function DirectChatRoute() {
  const { colleagueUid } = useParams({ strict: false })
  const agents = useQuery(agentsQuery)
  const client = useQueryClient()
  const colleague = agents.data?.agents.find(agent => agent.uid === colleagueUid)
  const started = useCallback(() => {
    void client.invalidateQueries({ queryKey: podKeys.agents })
  }, [client])
  if (agents.isPending) return <ChatHomeToolbar />
  if (agents.error) return <RequestFailure error={agents.error} retry={() => void agents.refetch()} />
  return (
    <ChatPage
      key={colleagueUid}
      colleagueUID={colleagueUid}
      conversationID={colleague?.directConversationID ?? undefined}
      onConversationStarted={started}
    />
  )
}

export function ChatPage({
  conversationID: requestedConversationID,
  colleagueUID,
  pageID,
  accessScope,
  pageHeader,
  onConversationStarted,
  onNewConversation,
  onExitConversation
}: {
  conversationID?: string
  colleagueUID?: string
  pageID?: string
  accessScope?: 'participants' | 'anchor_page'
  pageHeader?: ReactNode
  onConversationStarted?: (id: string) => void
  onNewConversation?: () => void
  onExitConversation?: () => void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const navigate = useNavigate(),
    client = useQueryClient()
  const { drafts, model, selectDraft } = useChatDraft(requestedConversationID, pageID, colleagueUID)
  const conversationID = requestedConversationID ?? model.conversationID.value
  const [sharing, setSharing] = useState(false),
    [summary, setSummary] = useState(false),
    [inspector, setInspector] = useState<InspectorTarget | null>(null),
    [finding, setFinding] = useState(false),
    [renaming, setRenaming] = useState(false),
    [deleting, setDeleting] = useState(false)
  const [findInitial, setFindInitial] = useState<{ key: string; query: string; messageID?: string }>()
  const root = useRef<HTMLElement>(null)
  const composerInput = useRef<HTMLTextAreaElement>(null)
  const inspectorTrigger = useRef<HTMLElement | null>(null)
  const pageQuote = drafts.pageQuote.value
  useEffect(() => {
    setInspector(null)
  }, [conversationID])
  useEffect(() => {
    if (!pageID || pageQuote?.pageID !== pageID) return
    drafts.pageQuote.value = null
    model.quote({ kind: 'page', id: pageID, quote: pageQuote.quote })
    composerInput.current?.focus()
  }, [drafts, pageID, pageQuote, model])
  const summaryTrigger = useRef<HTMLButtonElement>(null)
  const isMobile = useIsMobile()
  const useSplitInspector = !isMobile && !pageID
  const rightPanelOpen = summary || (useSplitInspector && !!inspector)
  const rightPanelMotion = usePanelMotion(rightPanelOpen)
  const changeSummary = (next: boolean, event?: PanelInputEvent) => {
    rightPanelMotion.prepare(next, event)
    if (next && useSplitInspector) setInspector(null)
    setSummary(next)
    if (!next) summaryTrigger.current?.focus()
  }
  const closeInspector = (event?: PanelInputEvent) => {
    if (useSplitInspector) rightPanelMotion.prepare(false, event)
    setInspector(null)
    if (inspectorTrigger.current?.isConnected) {
      inspectorTrigger.current.focus({ preventScroll: true })
    }
  }
  const openInspector = (target: InspectorTarget, trigger?: HTMLElement | null, event?: PanelInputEvent) => {
    const sameTarget =
      !target.fromSummary &&
      ((target.type === 'execution' &&
        isExecutionActive(
          inspector,
          target.initialRun ?? ({ id: target.runID, kind: target.kind } as NonNullable<typeof target.initialRun>)
        )) ||
        (target.type === 'peer' && isPeerActive(inspector, target.exchangeID)))
    if (sameTarget) {
      closeInspector(event)
      return
    }
    inspectorTrigger.current =
      trigger ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null)
    const fromSummary = target.fromSummary ?? (useSplitInspector && summary)
    if (useSplitInspector) {
      rightPanelMotion.prepare(true, event)
      if (summary) setSummary(false)
    }
    setInspector({ ...target, fromSummary })
  }
  const backToSummary = () => {
    setInspector(null)
    setSummary(true)
  }
  const toggleSummaryFromKeyboard = useEffectEvent(() => changeSummary(!summary))
  const findInput = useRef<HTMLInputElement>(null)
  const findReturnFocus = useRef<HTMLElement | null>(null)
  const closeFinding = useCallback(() => {
    setFinding(false)
    setFindInitial(undefined)
    const target = findReturnFocus.current?.isConnected ? findReturnFocus.current : root.current
    target?.focus({ preventScroll: true })
  }, [])
  const openFinding = useCallback(() => {
    if (finding) {
      findInput.current?.focus()
      findInput.current?.select()
    } else {
      findReturnFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
      setFinding(true)
    }
  }, [finding])
  const toggleFinding = useCallback(() => {
    if (finding) closeFinding()
    else openFinding()
  }, [finding, closeFinding, openFinding])
  const actions = useRoomActions(conversationID ?? '')
  const agents = useQuery(agentsQuery)
  const query = conversationQuery(conversationID ?? '')
  const detail = useQuery({
    ...query,
    queryFn: async context => {
      const observation = model.activityRead()
      const result = await query.queryFn(context)
      for (const activity of result.activities) model.observeActivity(activity, observation)
      return result
    },
    enabled: !!conversationID && !model.gone.value,
    refetchInterval: query =>
      query.state.data?.conversation.rowStatus === 'running_background' ||
      query.state.data?.linkedRuns.some(run => isLiveExecutionStatus(run.status))
        ? 4000
        : false
  })
  const data = detail.data,
    history = useChatHistory(conversationID, data)
  // The read position from before this visit stays fixed, so marking the room read does not move the divider.
  const [entry, setEntry] = useState<ChatEntry & { id: string }>()
  if (data && conversationID && entry?.id !== conversationID) {
    setEntry({ id: conversationID, readSeq: data.conversation.viewer.lastReadSeq, lastSeq: data.messageRange.lastSeq })
  }
  const location = useLocation()
  const navigationState = location.state as (Partial<PodCommandNavigationState> & { __TSR_key?: string }) | null
  const findMessage = pageID ? undefined : navigationState?.findMessage
  const findKey = navigationState?.__TSR_key ?? location.href
  const handledFind = useRef<string | undefined>(undefined)
  const findPages = useRef(0)
  useEffect(() => {
    if (!findMessage || !data || handledFind.current === findKey || history.isPending) return
    const step = findMessageStep(data, findMessage.seq, findPages.current, !!history.error)
    if (step === 'load_older') {
      findPages.current += 1
      history.mutate(null)
      return
    }
    handledFind.current = findKey
    findPages.current = 0
    findReturnFocus.current = null
    setFindInitial({ key: findKey, query: findMessage.query, messageID: step.messageID })
    setFinding(true)
  }, [data, findKey, findMessage, history])
  const nonAssistantPageChat =
    !!pageID && !!data && !detail.error && data.conversation.conversationKind !== 'assistant_task'
  useEffect(() => {
    if (nonAssistantPageChat) onNewConversation?.()
  }, [nonAssistantPageChat, onNewConversation])
  const assistant = agents.data?.personalAssistant
  const availableAgents = [...(agents.data?.agents ?? []), ...(assistant ? [assistant] : [])]
  const selected = colleagueUID ?? model.selectedAgentUID.value
  const personalAssistant = data
    ? data.conversation.conversationKind === 'assistant_task'
    : !!agents.data?.personalAssistantAvailable && !selected
  const agentUID =
    data?.conversation.agents.find(agent => agent.uid === model.targetAgentUID.value)?.uid ??
    data?.conversation.agents[0]?.uid ??
    (personalAssistant
      ? (assistant?.uid ?? '')
      : selected
        ? (availableAgents.find(agent => agent.uid === selected)?.uid ?? '')
        : (availableAgents[0]?.uid ?? ''))
  const callableAgents = [
    ...new Map(
      [...availableAgents, ...(data?.conversation.agents.filter(agent => agent.canChat) ?? [])].map(agent => [
        agent.uid,
        agent
      ])
    ).values()
  ]
  const commands = useChatCommands({
    model,
    drafts,
    conversationID,
    pageID,
    accessScope,
    data,
    agentUID,
    agentsError: !agents.isSuccess,
    personalAssistant,
    callableAgentUIDs: callableAgents.map(agent => agent.uid),
    refresh: () => refreshConversationDetail(client, conversationID!)
  })
  const remove = useMutation({
    mutationFn: () => deleteConversation({ path: { id: conversationID! }, query: { forceStop: true } }),
    onSuccess: () => {
      setDeleting(false)
      model.markGone()
      client.removeQueries({ queryKey: podKeys.detail(conversationID!) })
      void client.invalidateQueries({ queryKey: podKeys.conversations })
      void client.invalidateQueries({ queryKey: podKeys.agents })
      if (pageID) void client.invalidateQueries({ queryKey: podKeys.pageConversations(pageID) })
      if (onExitConversation) onExitConversation()
      else void navigate({ to: podLocation('/').pathname })
    }
  })
  useEffect(() => {
    if (!requestedConversationID && conversationID) {
      if (onConversationStarted) onConversationStarted(conversationID)
      else void navigate({ to: podLocation(`/conversations/${conversationID}`).pathname })
    }
  }, [requestedConversationID, conversationID, onConversationStarted, navigate])
  const gone = model.gone.value || conversationNotFound(detail.error)
  useConversationEvents(gone ? undefined : conversationID, model, onExitConversation)
  useEffect(() => {
    if (data) {
      model.reconcile(data.messages)
      drafts.remember(model, data.conversation.id, data.conversation.pageID ?? undefined)
    }
  }, [data, drafts, model])
  useEffect(() => {
    if (conversationID && conversationNotFound(detail.error)) {
      model.markGone()
      client.removeQueries({ queryKey: podKeys.detail(conversationID), exact: true })
    }
  }, [client, conversationID, detail.error, model])
  const lastReadSeq = data?.conversation.viewer.lastReadSeq,
    lastSeq = data?.messageRange.lastSeq
  const visitedRoom = useRef<string | null>(null)
  const atBottom = model.reading.value[pageID ? 'page' : 'standalone']?.atBottom !== false
  useEffect(() => {
    const markRead = () => {
      if (
        conversationID &&
        lastSeq &&
        lastReadSeq != null &&
        (visitedRoom.current !== conversationID || (lastReadSeq < lastSeq && atBottom)) &&
        document.visibilityState === 'visible'
      ) {
        visitedRoom.current = conversationID
        actions.update.mutate({ lastReadSeq: atBottom ? lastSeq : lastReadSeq })
      }
    }
    markRead()
    document.addEventListener('visibilitychange', markRead)
    return () => document.removeEventListener('visibilitychange', markRead)
  }, [conversationID, lastReadSeq, lastSeq, atBottom])
  const roomReady = !!data && !gone
  useEffect(() => {
    const element = root.current
    if (!element || !conversationID) return
    const handle = (event: KeyboardEvent) => {
      if (event.isComposing || event.repeat) return
      if (
        (event.metaKey || event.ctrlKey) &&
        !event.altKey &&
        !event.shiftKey &&
        ['f', 'i'].includes(event.key.toLowerCase())
      ) {
        event.preventDefault()
        if (event.key.toLowerCase() === 'f') openFinding()
        else toggleSummaryFromKeyboard()
      }
    }
    element.addEventListener('keydown', handle)
    return () => element.removeEventListener('keydown', handle)
  }, [conversationID, roomReady, openFinding])
  const composer = (
    <Composer
      model={model}
      agents={callableAgents}
      personalAssistant={personalAssistant}
      assistantAvailable={!!agents.data?.personalAssistantAvailable}
      directColleague={!!colleagueUID}
      agentsLoaded={agents.isSuccess}
      agentUID={agentUID}
      detail={data}
      commands={commands}
      variant={conversationID ? 'compact' : 'hero'}
      onInvite={() => setSharing(true)}
      onRename={() => setRenaming(true)}
      onSummary={() => changeSummary(true)}
      onNew={onNewConversation}
      inputRef={composerInput}
      answering={actions.answer.isPending}
      onAnswer={(interactionID, answer) => actions.answer.mutateAsync({ interactionID, answer })}
    />
  )
  const failure = model.error.value
  const retry = (
    <Button size="sm" variant="outline" onClick={() => commands.submit()} disabled={!commands.canSubmit}>
      {t('pod.chat.retry_send')}
    </Button>
  )
  if (nonAssistantPageChat) return <>{pageHeader}</>
  if (!conversationID && !colleagueUID && !pageID && agents.isSuccess && !agents.data.personalAssistantAvailable) {
    return (
      <section className="pod-chat pod-chat-standalone">
        <ChatHomeToolbar />
        <p className="m-auto p-6 text-sm text-fg-secondary">{t('pod.superagent.choose_colleague')}</p>
      </section>
    )
  }
  if (!conversationID) {
    return (
      <section
        ref={root}
        className={cn('pod-chat pod-chat-empty', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
        {pageHeader ?? (!pageID && <ChatHomeToolbar />)}
        <ChatHomeView
          composer={composer}
          pageID={pageID}
          colleague={colleagueUID ? availableAgents.find(agent => agent.uid === colleagueUID) : undefined}
          showSuggestions={!model.hasContent.value && !model.links.value.length}
          onSuggestion={text => {
            model.draft.value = text
            composerInput.current?.focus()
          }}>
          {agents.isPending && (
            <p role="status" className="pod-chat-status">
              {t('pod.chat.loading_agents')}
            </p>
          )}
          {agents.isError && <RequestFailure error={agents.error} retry={() => void agents.refetch()} />}
          {agents.isSuccess && selected && !agentUID && (
            <p role="status" className="pod-chat-status">
              {t('pod.chat.selected_agent_unavailable')}
            </p>
          )}
          {!agents.isPending && !agents.isError && !availableAgents.length && !personalAssistant && (
            <p className="pod-chat-status">{t('pod.chat.no_agents')}</p>
          )}
          {!!failure && <RequestFailure error={failure} action={retry} sendFailure />}
          {!pageID && <UnconfirmedChats current={model} select={selectDraft} />}
        </ChatHomeView>
      </section>
    )
  }
  if (gone) {
    return (
      <section className={cn('pod-chat flex-col', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
        {pageHeader ?? (!pageID && <ChatHomeToolbar />)}
        <ConversationGone model={model} onNewConversation={onExitConversation ?? onNewConversation} />
      </section>
    )
  }
  if (!data) {
    return (
      <section className={cn('pod-chat flex-col', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
        {pageHeader ?? (!pageID && <ChatHomeToolbar />)}
        <div className="pod-chat-loading">
          {detail.isError ? (
            <RequestFailure error={detail.error} retry={() => void detail.refetch()} />
          ) : (
            <p role="status">{t('pod.chat.loading_history')}</p>
          )}
        </div>
      </section>
    )
  }
  if (pageID && data.conversation.pageID !== pageID) {
    return (
      <section className="pod-chat pod-chat-embedded flex-col">
        {pageHeader}
        <p role="alert" className="p-4 text-sm">
          {t('pod.page_chat.wrong_page')}
        </p>
      </section>
    )
  }
  const messages = mergeMessages(
    data.messages,
    model.pending.value,
    data.pendingQueues,
    data.conversation.participants.filter(member => member.type === 'human').length
  )
  const liveStreams = Object.values(model.liveStreams.value)
    .filter(stream => data.conversation.agents.some(agent => agent.uid === stream.agentUID))
    .map(stream => ({
      ...stream,
      agentName: stream.agentName || data.conversation.agents.find(agent => agent.uid === stream.agentUID)?.displayName,
      activity: model.activities.value[stream.agentUID]
    }))
  const activity = Object.values(model.activities.value).find(
    activity => activity.state === 'active' && data.conversation.agents.some(agent => agent.uid === activity.agentUID)
  )
  const workingQueues = data.pendingQueues.filter(queue => queue.workStatus.state !== 'idle')
  const running = workingQueues.some(queue => queue.workStatus.state === 'running')
  const waiting = !running && workingQueues.some(queue => queue.workStatus.state === 'queued')
  const retryAt = workingQueues
    .flatMap(queue =>
      queue.workStatus.state === 'retrying' && queue.workStatus.retryAt ? [queue.workStatus.retryAt] : []
    )
    .sort()[0]
  const retryTime =
    !running && !waiting && retryAt
      ? new Date(retryAt).toLocaleTimeString(i18n.language, { hour: '2-digit', minute: '2-digit' })
      : undefined
  return (
    <section ref={root} tabIndex={-1} className={cn('pod-chat', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
      {pageID ? (
        pageHeader
      ) : (
        <RoomHeader
          detail={data}
          onInvite={() => setSharing(true)}
          onFind={toggleFinding}
          onSummary={event => changeSummary(!summary, event)}
          summaryOpen={summary}
          summaryTrigger={summaryTrigger}
          onDelete={() => setDeleting(true)}
          onExitConversation={onExitConversation}
          editing={renaming}
          onEditingChange={setRenaming}
        />
      )}
      {finding && (
        <SessionFindBar
          key={findInitial?.key}
          root={root}
          history={history}
          inputRef={findInput}
          initial={findInitial}
          onClose={closeFinding}
        />
      )}
      <div className="pod-chat-room-body">
        <div className="pod-chat-room-main">
          <ErrorBoundary
            variant="panel"
            className="m-4 content-start"
            resetKeys={[conversationID, data]}
            onReset={() => void refreshConversationDetail(client, conversationID)}>
            <TurnTimeline
              model={model}
              presentation={pageID ? 'page' : 'standalone'}
              unreadMessageID={entry?.id === conversationID ? firstUnreadMessageID(data, entry) : undefined}
              history={history}
              messages={messages}
              viewerUID={data.conversation.viewer.uid}
              members={data.conversation.participants}
              working={commands.working}
              waiting={waiting}
              activity={activity}
              retryTime={retryTime}
              conversationID={conversationID}
              conversationTitle={data.conversation.title}
              onRefresh={() => void refreshConversationDetail(client, conversationID)}
              retryableMessageIDs={data.pendingQueues.flatMap(queue =>
                queue.retryableMessageID ? [queue.retryableMessageID] : []
              )}
              actions={commands.messageActions}
              latestInput={data.latestInput}
              liveStreams={liveStreams}
              pendingInteractions={data.pendingInteractions}
              linkedRuns={data.linkedRuns.map(run => ({
                ...run,
                agentName:
                  data.conversation.agents.find(agent => agent.uid === run.agentUID)?.displayName ??
                  data.messages.findLast(
                    message => message.authorType === 'agent' && message.authorUID === run.agentUID
                  )?.authorDisplayName
              }))}
              showAgentOnRuns={data.conversation.roomMode === 'group' && data.conversation.agents.length > 1}
              activeInspector={inspector}
              onOpenInspector={openInspector}
              canAnswer={uid => availableAgents.some(agent => agent.uid === uid && agent.active)}
              readOnlyReason={t('pod.chat_room.answer_unavailable')}
              onAnswer={(interactionID, answer) => actions.answer.mutateAsync({ interactionID, answer })}
              onResolveActionCard={(cardID, decision) => actions.resolveActionCard.mutateAsync({ cardID, decision })}
              onComposeAnswer={
                !model.editing.value && !actions.answer.isPending
                  ? (interactionID, text) => {
                      if (model.startAnswer(interactionID, text)) {
                        composerInput.current?.focus()
                      }
                    }
                  : undefined
              }
              onQuote={(quote, message) => {
                model.quote({ kind: 'message', id: message.id, quote })
                composerInput.current?.focus()
              }}
            />
          </ErrorBoundary>
          <div className="pod-chat-composer-dock">
            <QueuedStrip
              detail={data}
              pending={commands.pendingQueueAction}
              callableAgentUIDs={availableAgents.map(agent => agent.uid)}
              disabled={commands.disabled}
              editing={!!model.editing.value}
              change={commands.changeQueue}
              edit={commands.editQueued}
              takeBack={commands.takeBackQueued}
            />
            {model.neededInvites.value.map(person => (
              <div key={person.uid} className="pod-chat-invite-notice">
                <span>{t('pod.chat_room.mention_outside', { name: person.displayName })}</span>
                <Button
                  size="xs"
                  variant="ghost"
                  disabled={actions.participants.isPending}
                  onClick={() =>
                    actions.participants.mutate(
                      { addUIDs: [person.uid] },
                      {
                        onSuccess: () => {
                          model.neededInvites.value = model.neededInvites.value.filter(item => item.uid !== person.uid)
                        }
                      }
                    )
                  }>
                  {t('pod.chat_room.invite')}
                </Button>
                <Button
                  size="xs"
                  variant="ghost"
                  onClick={() => {
                    model.neededInvites.value = model.neededInvites.value.filter(item => item.uid !== person.uid)
                  }}>
                  {t('pod.chat_room.dismiss')}
                </Button>
              </div>
            ))}
            {!!commands.queueError && <RequestFailure error={commands.queueError} />}
            {commands.editConflict && <EditRecovery model={model} data={data} recovery={commands.recovery} />}
            {!!commands.recovery.error && <RequestFailure error={commands.recovery.error} />}
            {agents.isError && <RequestFailure error={agents.error} retry={() => void agents.refetch()} />}
            {detail.isError && <RequestFailure error={detail.error} retry={() => void detail.refetch()} />}
            {model.connecting.value && (
              <p role="status" className="text-xs text-fg-tertiary">
                {t('pod.chat.reconnecting')}
              </p>
            )}
            {!!failure && <RequestFailure error={failure} action={retry} sendFailure />}
            {composer}
          </div>
        </div>
        <PodPanelPresence animate={!isMobile && rightPanelMotion.animate}>
          {summary ? (
            <ErrorBoundary
              key="summary"
              variant="panel"
              className="m-3 w-72 shrink-0 self-start"
              resetKeys={[conversationID]}>
              <ChatSummaryPanel
                detail={data}
                callableAgentUIDs={availableAgents.map(agent => agent.uid)}
                activeInspector={inspector}
                onOpenInspector={openInspector}
                onClose={event => changeSummary(false, event)}
              />
            </ErrorBoundary>
          ) : useSplitInspector && inspector ? (
            <ErrorBoundary
              key="inspector"
              variant="panel"
              className="m-3 w-96 shrink-0 self-start"
              resetKeys={[conversationID, inspector.type === 'peer' ? inspector.exchangeID : inspector.runID]}>
              <ExecutionInspectorPanel
                conversationID={conversationID}
                target={inspector}
                variant="panel"
                finalFocus={inspectorTrigger}
                resolveAgentName={uid =>
                  data.conversation.agents.find(agent => agent.uid === uid)?.displayName ??
                  availableAgents.find(agent => agent.uid === uid)?.displayName ??
                  data.messages.findLast(message => message.authorType === 'agent' && message.authorUID === uid)
                    ?.authorDisplayName
                }
                onClose={closeInspector}
                onBackToSummary={backToSummary}
                onSwitchTarget={setInspector}
              />
            </ErrorBoundary>
          ) : null}
        </PodPanelPresence>
      </div>
      {!useSplitInspector && inspector && (
        <ExecutionInspectorPanel
          conversationID={conversationID}
          target={inspector}
          variant="sheet"
          finalFocus={inspectorTrigger}
          resolveAgentName={uid =>
            data.conversation.agents.find(agent => agent.uid === uid)?.displayName ??
            availableAgents.find(agent => agent.uid === uid)?.displayName ??
            data.messages.findLast(message => message.authorType === 'agent' && message.authorUID === uid)
              ?.authorDisplayName
          }
          onClose={closeInspector}
          onSwitchTarget={setInspector}
        />
      )}
      {data.conversation.conversationKind === 'group' ? (
        <SharePopover detail={data} open={sharing} onOpenChange={setSharing} />
      ) : (
        <NewGroupDialog detail={data} open={sharing} onOpenChange={setSharing} />
      )}
      <Dialog open={deleting} onOpenChange={open => !remove.isPending && setDeleting(open)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!remove.isPending}>
          <DialogTitle>{t(commands.working ? 'pod.chat_room.stop_delete' : 'pod.chat_room.delete')}</DialogTitle>
          <p>
            {t('pod.content.deleting_cannot_be_undone_pages_saved_to_pod_will_be', { title: data.conversation.title })}
          </p>
          {remove.error && <RequestFailure error={remove.error} />}
          <DialogFooter>
            <Button variant="outline" disabled={remove.isPending} onClick={() => setDeleting(false)}>
              {t('pod.content.cancel')}
            </Button>
            <Button variant="destructive" disabled={remove.isPending} onClick={() => remove.mutate()}>
              {t('pod.chat_room.delete')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}

function EditRecovery({
  model,
  data,
  recovery
}: {
  model: InstanceType<typeof ChatModel>
  data: ConversationDetail
  recovery: ChatCommands['recovery']
}) {
  useSignals()
  const { t } = useTranslation()
  const editing = model.editing.value
  if (!editing) return null
  const saved = editingSnapshot(data, editing)
  const conflict = saved && model.savedEditChanged(saved)
  return (
    <div className="space-y-2 text-[13px] leading-5">
      <Button type="button" size="sm" variant="outline" disabled={recovery.loading} onClick={recovery.refresh}>
        {t('pod.chat.refresh_edit')}
      </Button>
      {saved === undefined && <p>{t('pod.chat.errors.input_already_started')}</p>}
      {conflict && (
        <>
          <p>{t('pod.chat.saved_message_changed')}</p>
          <blockquote className="max-h-28 overflow-auto border-l-2 border-border pl-3 whitespace-pre-wrap break-words">
            {saved.text}
          </blockquote>
          <Button type="button" size="sm" variant="outline" disabled={recovery.loading} onClick={recovery.useSaved}>
            {t('pod.chat.load_saved_message')}
          </Button>
        </>
      )}
    </div>
  )
}

function ConversationGone({
  model,
  onNewConversation
}: {
  model: InstanceType<typeof ChatModel>
  onNewConversation?: () => void
}) {
  useSignals()
  const { t } = useTranslation()
  const drafts = [
    ...new Set([model.draft.value, model.pending.value?.text ?? '', model.editing.value?.previousDraft ?? ''])
  ]
    .filter(text => text.trim() !== '')
    .map((text, index) => ({ key: String(index), text }))
  return (
    <section className="pod-chat-loading pod-chat-gone">
      <p role="alert" className="text-[13px] text-fg-tertiary">
        {t('pod.chat.errors.conversation_not_found')}
      </p>
      <LocalChatDrafts drafts={drafts} />
      <ChatAttachmentDrafts model={model.attachments} recovery />
      {onNewConversation ? (
        <Button variant="outline" onClick={onNewConversation}>
          {t('pod.chat.new_conversation')}
        </Button>
      ) : (
        <Link to={podLocation('/').pathname} className={buttonVariants({ variant: 'outline' })}>
          {t('pod.chat.new_conversation')}
        </Link>
      )}
    </section>
  )
}

function RequestFailure({
  error,
  retry,
  action,
  sendFailure
}: {
  error: unknown
  retry?: () => void
  action?: ReactNode
  sendFailure?: boolean
}) {
  const { t } = useTranslation()
  return (
    <div role="alert" className="space-y-2 text-[13px] leading-5">
      <p className="text-destructive">{requestErrorMessage(chatError(error))}</p>
      {sendFailure ? <p className="text-fg-tertiary">{t('pod.chat.draft_preserved')}</p> : null}
      {action ??
        (retry ? (
          <Button size="sm" variant="outline" onClick={retry}>
            {t('pod.chat.retry_load')}
          </Button>
        ) : null)}
    </div>
  )
}
