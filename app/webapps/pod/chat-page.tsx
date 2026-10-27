import { podLocation, podRouteID } from '../common/browser-context'
import { Button, cn, Dialog, DialogContent, DialogTitle, DialogFooter } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate, useParams } from '@tanstack/react-router'
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
import { LocalChatDrafts, UnconfirmedChats, useChatDraft } from './chat-drafts'
import { useChatHistory } from './chat-history'
import { editingSnapshot, useChatCommands, type ChatCommands } from './chat-commands'
import { ChatAttachmentDrafts } from './chat-attachments'
import { useConversationEvents } from './use-conversation-events'
import { refreshConversationDetail } from './query-cache'
import { deleteConversation } from './api/generated/sdk.gen'
import { Composer } from './chat/composer'
import { TurnTimeline } from './chat/turn-timeline'
import { ChatHomeView, ChatHomeToolbar } from './chat/chat-home-view'
import { RoomHeader, type PageChatHeaderControls } from './chat/room-header'
import { SharePopover } from './chat/share-popover'
import { ChatSummaryPanel } from './chat/chat-summary-panel'
import { SessionFindBar } from './chat/session-find-bar'
import { QueuedStrip } from './chat/queued-strip'
import { useRoomActions } from './chat/room-api'
import './chat.css'

export function ChatRoute() {
  const { conversationID } = useParams({ strict: false })
  const location = useLocation()
  const fullID = podRouteID(conversationID)
  const locationKey = (location.state as { __TSR_key?: string } | null)?.__TSR_key ?? location.href
  return <ChatPage key={fullID ?? conversationID ?? locationKey} conversationID={fullID ?? conversationID} />
}

export function ChatPage({
  conversationID: requestedConversationID,
  pageID,
  accessScope,
  pageHeader,
  pageChat,
  onConversationStarted,
  onNewConversation,
  onExitConversation
}: {
  conversationID?: string
  pageID?: string
  accessScope?: 'participants' | 'anchor_page'
  pageHeader?: ReactNode
  pageChat?: PageChatHeaderControls
  onConversationStarted?: (id: string) => void
  onNewConversation?: () => void
  onExitConversation?: () => void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const navigate = useNavigate(),
    client = useQueryClient()
  const { drafts, model, selectDraft } = useChatDraft(requestedConversationID, pageID)
  const conversationID = requestedConversationID ?? model.conversationID.value
  const [sharing, setSharing] = useState(false),
    [summary, setSummary] = useState(false),
    [finding, setFinding] = useState(false),
    [renaming, setRenaming] = useState(false),
    [deleting, setDeleting] = useState(false)
  const root = useRef<HTMLElement>(null)
  const composerInput = useRef<HTMLTextAreaElement>(null)
  const summaryTrigger = useRef<HTMLButtonElement>(null)
  const findInput = useRef<HTMLInputElement>(null)
  const findReturnFocus = useRef<HTMLElement | null>(null)
  const closeFinding = useCallback(() => {
    setFinding(false)
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
      query.state.data?.linkedRuns.some(run => ['queued', 'running', 'waiting_on_user'].includes(run.status))
        ? 2000
        : false
  })
  const data = detail.data,
    history = useChatHistory(conversationID, data)
  const availableAgents = agents.data?.agents ?? []
  const selected = model.selectedAgentUID.value
  const agentUID =
    data?.conversation.agents.find(agent => agent.uid === model.targetAgentUID.value)?.uid ??
    data?.conversation.agents[0]?.uid ??
    (availableAgents.some(agent => agent.uid === selected) ? selected : (availableAgents[0]?.uid ?? ''))
  const commands = useChatCommands({
    model,
    drafts,
    conversationID,
    pageID,
    accessScope,
    data,
    agentUID,
    agentsError: agents.isError,
    callableAgentUIDs: availableAgents.map(agent => agent.uid),
    refresh: () => refreshConversationDetail(client, conversationID!)
  })
  const remove = useMutation({
    mutationFn: () => deleteConversation({ path: { id: conversationID! }, query: { forceStop: true } }),
    onSuccess: () => {
      setDeleting(false)
      model.markGone()
      client.removeQueries({ queryKey: podKeys.detail(conversationID!) })
      void client.invalidateQueries({ queryKey: podKeys.conversations })
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
  const atBottom = model.reading.value[pageID ? 'page' : 'standalone']?.atBottom !== false
  useEffect(() => {
    const markRead = () => {
      if (
        conversationID &&
        lastSeq &&
        lastReadSeq != null &&
        lastReadSeq < lastSeq &&
        atBottom &&
        document.visibilityState === 'visible'
      ) {
        actions.update.mutate({ lastReadSeq: lastSeq })
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
        else setSummary(value => !value)
      }
    }
    element.addEventListener('keydown', handle)
    return () => element.removeEventListener('keydown', handle)
  }, [conversationID, roomReady, openFinding])
  const composer = (
    <Composer
      model={model}
      agents={availableAgents}
      agentsLoaded={agents.isSuccess}
      agentUID={agentUID}
      detail={data}
      commands={commands}
      variant={conversationID ? 'compact' : 'hero'}
      onInvite={() => setSharing(true)}
      onRename={() => setRenaming(true)}
      onSummary={() => setSummary(true)}
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
  if (!conversationID) {
    return (
      <section
        ref={root}
        className={cn('pod-chat pod-chat-empty', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
        {pageHeader ?? (!pageID && <ChatHomeToolbar />)}
        <ChatHomeView
          composer={composer}
          pageID={pageID}
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
          {!agents.isPending && !agents.isError && !availableAgents.length && (
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
      <RoomHeader
        detail={data}
        embedded={!!pageID}
        pageChat={pageChat}
        onInvite={() => setSharing(true)}
        onFind={toggleFinding}
        onSummary={() => setSummary(value => !value)}
        summaryOpen={summary}
        summaryTrigger={summaryTrigger}
        onDelete={() => setDeleting(true)}
        onExitConversation={onExitConversation}
        editing={renaming}
        onEditingChange={setRenaming}
      />
      {finding && <SessionFindBar root={root} history={history} inputRef={findInput} onClose={closeFinding} />}
      <div className="pod-chat-room-body">
        <div className="pod-chat-room-main">
          <TurnTimeline
            model={model}
            presentation={pageID ? 'page' : 'standalone'}
            history={history}
            messages={messages}
            viewerUID={data.conversation.viewer.uid}
            members={data.conversation.participants}
            working={commands.working}
            waiting={waiting}
            activity={activity}
            retryTime={retryTime}
            conversationID={conversationID}
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
                data.messages.findLast(message => message.authorType === 'agent' && message.authorUID === run.agentUID)
                  ?.authorDisplayName
            }))}
            canAnswer={uid =>
              data.conversation.agents.some(agent => agent.uid === uid && agent.active) &&
              availableAgents.some(agent => agent.uid === uid)
            }
            readOnlyReason={t('pod.chat_room.answer_unavailable')}
            onAnswer={(interactionID, answer) => actions.answer.mutateAsync({ interactionID, answer })}
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
              model.links.value = [
                ...model.links.value.filter(link => link.kind !== 'message'),
                { kind: 'message', id: message.id, quote }
              ]
              composerInput.current?.focus()
            }}
          />
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
        {summary && (
          <ChatSummaryPanel
            detail={data}
            callableAgentUIDs={availableAgents.map(agent => agent.uid)}
            onClose={() => {
              setSummary(false)
              summaryTrigger.current?.focus()
            }}
          />
        )}
      </div>
      <SharePopover detail={data} open={sharing} onOpenChange={setSharing} />
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
        <Button render={<Link to={podLocation('/').pathname} />} nativeButton={false} variant="outline">
          {t('pod.chat.new_conversation')}
        </Button>
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
