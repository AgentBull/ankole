import { podLocation, podRouteID } from '../common/browser-context'
import {
  Button,
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupTextarea,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  SidebarTrigger,
  useSidebar,
  useReducedMotion,
  toast,
  cn
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiAddLine,
  RiArrowDownLine,
  RiArrowUpLine,
  RiCheckLine,
  RiDeleteBinLine,
  RiEditLine,
  RiFileCopyLine,
  RiRestartLine,
  RiSendPlaneLine,
  RiStopFill
} from '@remixicon/react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { useStickToBottom } from 'use-stick-to-bottom'
import { InternalAPIError } from '../common/internal-api-client'
import { MarkdownBody } from '../common/markdown-body'
import { linkTarget } from '../common/router'
import { MessageArtifacts } from './message-artifacts'
import { requestErrorCode, requestErrorMessage } from '../common/request-errors'
import {
  agentsQuery,
  conversationNotFound,
  conversationQuery,
  podKeys,
  type PodActivity,
  type PodActivityItem,
  type PodAgent,
  type ConversationPendingInput,
  type ConversationQueueRequest,
  type ConversationDetail
} from './api'
import { ChatModel, mergeMessages, shouldSendOnEnter, type ChatPresentation, type DisplayMessage } from './state/chat'
import { LocalChatDrafts, UnconfirmedChats, useChatDraft } from './chat-drafts'
import { OlderMessages, useChatHistory, useChatReading, messageID } from './chat-history'
import { editingText, useChatCommands, type ChatCommands } from './chat-commands'
import {
  ChatAttachmentButton,
  ChatAttachmentDrafts,
  MessageAttachments,
  chatAttachmentHandlers
} from './chat-attachments'
import { useConversationEvents } from './use-conversation-events'
import { pageQuery } from './content-api'
import { ModelControls } from './model-controls'
import { PageIcon } from './page-icon'
import './chat.css'

export function ChatRoute() {
  const { conversationID } = useParams({ strict: false })
  const location = useLocation()
  const fullID = podRouteID(conversationID)
  const locationKey = (location.state as { __TSR_key?: string; key?: string } | null)?.__TSR_key ?? location.href
  return <ChatPage key={fullID ?? conversationID ?? locationKey} conversationID={fullID ?? conversationID} />
}

export function ChatPage({
  conversationID: requestedConversationID,
  pageID,
  onConversationStarted
}: {
  conversationID?: string
  pageID?: string
  onConversationStarted?: (id: string) => void
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const navigate = useNavigate()
  const client = useQueryClient()
  const { drafts, model, selectDraft } = useChatDraft(requestedConversationID, pageID)
  const conversationID = requestedConversationID ?? model.conversationID.value
  const agents = useQuery({ ...agentsQuery, enabled: !conversationID })
  const query = conversationQuery(conversationID ?? '')
  const detail = useQuery({
    ...query,
    queryFn: async context => {
      const observation = model.activityRead()
      const detail = await query.queryFn(context)
      model.observeActivity(detail.status.activity, observation)
      return detail
    },
    enabled: !!conversationID && !model.gone.value
  })
  const data = detail.data
  const history = useChatHistory(conversationID, data)
  const availableAgents = agents.data?.agents ?? []
  const selection = model.selectedAgentUID.value
  const selectedAgentUID = availableAgents.some(agent => agent.uid === selection) ? selection : ''
  const agentUID =
    data?.conversation.agent.uid ?? (availableAgents.length === 1 ? availableAgents[0]!.uid : selectedAgentUID)
  const commands = useChatCommands({
    model,
    drafts,
    conversationID,
    pageID,
    data,
    agentUID,
    agentsError: agents.isError,
    refresh: async () => (await detail.refetch({ cancelRefetch: true, throwOnError: true })).data
  })
  const { disabled, working, submit } = commands

  useEffect(() => {
    if (!requestedConversationID && conversationID) {
      if (onConversationStarted) onConversationStarted(conversationID)
      else void navigate({ to: podLocation(`/conversations/${conversationID}`).pathname })
    }
  }, [requestedConversationID, conversationID, onConversationStarted, navigate])

  const gone = model.gone.value || conversationNotFound(detail.error)
  useConversationEvents(gone ? undefined : conversationID, model)
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

  const composer = (
    <Composer
      model={model}
      agents={availableAgents}
      agentUID={agentUID}
      existingAgent={data?.conversation.agent.displayName}
      commands={commands}
      conversationID={conversationID}
      activeSignalID={working ? (model.activity.value?.signalID ?? data?.status.activity.signalID) : null}
    />
  )
  const failure = model.error.value
  const retry = (
    <Button size="sm" variant="outline" onClick={() => submit()} disabled={!commands.canSubmit}>
      {t('pod.chat.retry_send')}
    </Button>
  )

  if (!conversationID) {
    return (
      <section className={cn('pod-chat pod-chat-empty', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
        {!pageID && <ChatHeader title={t('pod.chat.new_conversation')} />}
        <div className="pod-chat-empty-content">
          <h1 className="pod-chat-empty-title">{t(pageID ? 'pod.page_chat.start_title' : 'pod.chat.new_title')}</h1>
          {pageID && <p className="pod-chat-empty-hint">{t('pod.page_chat.start_hint')}</p>}
          {agents.isPending ? (
            <p role="status" className="pod-chat-status">
              {t('pod.chat.loading_agents')}
            </p>
          ) : null}
          {agents.isError ? <RequestFailure error={agents.error} retry={() => void agents.refetch()} /> : null}
          {!agents.isPending && !agents.isError && !availableAgents.length ? (
            <p className="pod-chat-status">{t('pod.chat.no_agents')}</p>
          ) : null}
        </div>
        <div className="pod-chat-composer-dock">
          {!pageID && <UnconfirmedChats current={model} select={selectDraft} />}
          {failure ? <RequestFailure error={failure} action={retry} sendFailure /> : null}
          {composer}
        </div>
      </section>
    )
  }
  if (gone) return <ConversationGone model={model} />
  if (!data) {
    return (
      <section className="pod-chat-loading">
        {detail.isError ? (
          <RequestFailure error={detail.error} retry={() => void detail.refetch()} />
        ) : (
          <p role="status" className="text-[13px] text-fg-tertiary">
            {t('pod.chat.loading_history')}
          </p>
        )}
      </section>
    )
  }
  const firstMessageID = data.messages.find(message => message.seq === 1 && message.authorType === 'human')?.id
  const pendingInputs = data.pendingInputs.filter(input => data.queuePaused || input.messageID !== firstMessageID)
  const pendingIDs = new Set(pendingInputs.map(input => input.messageID))
  const messages = mergeMessages(
    data.messages.filter(message => !pendingIDs.has(message.id)),
    model.pending.value,
    model.live.value
  )
  if (pageID && data.conversation.pageID !== pageID) {
    return (
      <p role="alert" className="p-4 text-sm">
        {t('pod.page_chat.wrong_page')}
      </p>
    )
  }
  const retryTime = data.status.retryAt
    ? new Date(data.status.retryAt).toLocaleTimeString(i18n.language, { hour: '2-digit', minute: '2-digit' })
    : undefined

  return (
    <section className={cn('pod-chat', pageID ? 'pod-chat-embedded' : 'pod-chat-standalone')}>
      {!pageID ? (
        <ChatHeader title={data.conversation.title} />
      ) : (
        <h1 className="sr-only">{data.conversation.title}</h1>
      )}
      {!pageID && data.conversation.pageID && (
        <ConversationPageLink pageID={data.conversation.pageID} conversationID={data.conversation.id} />
      )}
      <MessageHistory
        model={model}
        presentation={pageID ? 'page' : 'standalone'}
        history={history}
        messages={messages}
        working={working}
        retryTime={retryTime}
        activity={model.activity.value}
        conversationID={conversationID}
        retryableMessageID={data.retryableMessageID}
        actions={commands.messageActions}
      />
      <div className="pod-chat-composer-dock">
        <PendingInputs
          conversationID={conversationID}
          inputs={pendingInputs}
          order={data.pendingInputs}
          paused={data.queuePaused}
          disabled={disabled}
          change={commands.changeQueue}
          edit={commands.editQueued}
        />
        {commands.queueError ? <RequestFailure error={commands.queueError} /> : null}
        {commands.editConflict && <EditRecovery model={model} data={data} recovery={commands.recovery} />}
        {commands.recovery.error ? <RequestFailure error={commands.recovery.error} /> : null}
        {detail.isError ? <RequestFailure error={detail.error} retry={() => void detail.refetch()} /> : null}
        {model.connecting.value ? (
          <p role="status" className="text-[13px] text-fg-tertiary">
            {t('pod.chat.reconnecting')}
          </p>
        ) : null}
        {!data.conversation.agent.active ? (
          <p className="text-[13px] text-fg-tertiary">{t('pod.chat.agent_unavailable')}</p>
        ) : null}
        {failure ? <RequestFailure error={failure} action={retry} sendFailure /> : null}
        {composer}
      </div>
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
  const saved = editingText(data, editing)
  const conflict = saved !== undefined && saved !== (editing.originalText ?? '')
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
            {saved}
          </blockquote>
          <Button type="button" size="sm" variant="outline" disabled={recovery.loading} onClick={recovery.useSaved}>
            {t('pod.chat.load_saved_message')}
          </Button>
        </>
      )}
    </div>
  )
}

function ConversationPageLink({ pageID, conversationID }: { pageID: string; conversationID: string }) {
  const { t } = useTranslation()
  const page = useQuery(pageQuery(pageID))
  return (
    <div className="pod-chat-page-reference">
      <Link
        className="link inline-flex items-center gap-1.5"
        {...linkTarget(podLocation(`/pages/${pageID}`, { chat: conversationID }))}>
        {page.data && <PageIcon page={page.data.page} />}
        {t('pod.page_chat.context_page')}: {page.data?.page.title || t('pod.content.untitled')}
      </Link>
    </div>
  )
}

function ChatHeader({ title }: { title: string }) {
  const { t } = useTranslation()
  const { state } = useSidebar()
  return (
    <header className="pod-chat-header">
      <SidebarTrigger className={state === 'expanded' ? 'md:hidden' : undefined} label={t('pod.sidebar.expand')} />
      <h1 className="pod-chat-header-title" title={title}>
        {title}
      </h1>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={t('pod.chat.new_conversation')}
        title={t('pod.chat.new_conversation')}
        nativeButton={false}
        render={<Link to={podLocation('/').pathname} />}>
        <RiAddLine aria-hidden />
      </Button>
    </header>
  )
}

function PendingInputs({
  conversationID,
  inputs,
  order,
  paused,
  disabled,
  change,
  edit
}: {
  conversationID: string
  inputs: ConversationPendingInput[]
  order: ConversationPendingInput[]
  paused: boolean
  disabled: boolean
  change(command: ConversationQueueRequest): void
  edit(input: ConversationPendingInput): void
}) {
  useSignals()
  const { t } = useTranslation()
  if (!inputs.length && !paused) return null
  const reorder = (index: number, offset: number) => {
    const ids = inputs.map(input => input.messageID)
    const [id] = ids.splice(index, 1)
    ids.splice(index + offset, 0, id!)
    const visible = new Set(ids)
    let position = 0
    const messageIDs = order.map(input => (visible.has(input.messageID) ? ids[position++]! : input.messageID))
    change({ action: 'reorder', messageIDs })
  }
  return (
    <section className="pod-chat-queue" aria-label={t('pod.chat.queue_title')}>
      <div className="pod-chat-queue-header">
        <h2>{t(paused ? 'pod.chat.queue_paused' : 'pod.chat.queue_title')}</h2>
        {paused && (
          <Button size="xs" variant="ghost" disabled={disabled} onClick={() => change({ action: 'resume' })}>
            {t('pod.chat.resume_queue')}
          </Button>
        )}
      </div>
      <ol className="pod-chat-queue-items">
        {inputs.map((input, index) => (
          <li key={input.messageID} className="pod-chat-queue-item">
            <div className="pod-chat-queue-text">
              <p>{input.text}</p>
              <MessageAttachments
                conversationID={conversationID}
                messageID={input.messageID}
                attachments={input.attachments}
              />
              <span>
                {t(input.deliveryMode === 'queue' ? 'pod.chat.pending_queue' : 'pod.chat.pending_steer')} ·{' '}
                {input.modelProfile === 'primary' ? t('pod.chat.model_follow_agent') : input.modelProfile}
              </span>
            </div>
            <div className="pod-chat-queue-actions">
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('pod.chat.edit_pending')}
                title={t('pod.chat.edit_pending')}
                disabled={disabled}
                onClick={() => edit(input)}>
                <RiEditLine aria-hidden />
              </Button>
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('pod.chat.move_earlier')}
                title={t('pod.chat.move_earlier')}
                disabled={disabled || index === 0}
                onClick={() => reorder(index, -1)}>
                <RiArrowUpLine aria-hidden />
              </Button>
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('pod.chat.move_later')}
                title={t('pod.chat.move_later')}
                disabled={disabled || index === inputs.length - 1}
                onClick={() => reorder(index, 1)}>
                <RiArrowDownLine aria-hidden />
              </Button>
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('pod.chat.send_now')}
                title={t('pod.chat.send_now')}
                disabled={disabled}
                onClick={() => change({ action: 'send_now', messageID: input.messageID })}>
                <RiSendPlaneLine aria-hidden />
              </Button>
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={t('pod.chat.remove_pending')}
                title={t('pod.chat.remove_pending')}
                disabled={disabled}
                onClick={() => change({ action: 'remove', messageID: input.messageID })}>
                <RiDeleteBinLine aria-hidden />
              </Button>
            </div>
          </li>
        ))}
      </ol>
    </section>
  )
}

function ConversationGone({ model }: { model: InstanceType<typeof ChatModel> }) {
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
      <Button render={<Link to={podLocation('/').pathname} />} nativeButton={false} variant="outline">
        {t('pod.chat.new_conversation')}
      </Button>
    </section>
  )
}

function Composer({
  model,
  agents,
  agentUID,
  existingAgent,
  commands,
  conversationID,
  activeSignalID
}: {
  model: InstanceType<typeof ChatModel>
  agents: PodAgent[]
  agentUID: string
  existingAgent?: string
  commands: ChatCommands
  conversationID?: string
  activeSignalID?: string | null
}) {
  const { disabled, sending, submit, working, followupRelevant, stop, canSubmit } = commands
  useSignals()
  const { t } = useTranslation()
  const textarea = useRef<HTMLTextAreaElement>(null)
  const editingID = model.editing.value?.messageID
  useEffect(() => {
    if (editingID) textarea.current?.focus()
  }, [editingID])
  return (
    <form
      {...chatAttachmentHandlers(model.attachments, disabled || !!model.editing.value)}
      className="pod-chat-composer"
      title={t('pod.chat.alternate_shortcut')}
      onSubmit={event => {
        event.preventDefault()
        submit()
      }}>
      {model.editing.value?.kind === 'last' && (
        <p className="pod-chat-action-hint">{t('pod.chat.retry_keeps_artifacts')}</p>
      )}
      <InputGroup className="pod-chat-composer-field">
        <ChatAttachmentDrafts model={model.attachments} disabled={disabled || !!model.editing.value} />
        <InputGroupTextarea
          ref={textarea}
          aria-label={t('pod.chat.message_label')}
          autoFocus
          className="pod-chat-composer-input"
          disabled={disabled && (sending || !!existingAgent || agents.length === 0)}
          placeholder={t('pod.chat.placeholder')}
          rows={1}
          value={model.draft.value}
          onChange={event => {
            model.draft.value = event.target.value
          }}
          onKeyDown={event => {
            if (event.key === 'Escape' && !event.nativeEvent.isComposing && model.editing.value) {
              event.preventDefault()
              model.cancelEdit()
              return
            }
            if (
              shouldSendOnEnter({
                key: event.key,
                shiftKey: event.shiftKey,
                isComposing: event.nativeEvent.isComposing,
                keyCode: event.nativeEvent.keyCode,
                ctrlKey: event.ctrlKey,
                metaKey: event.metaKey
              })
            ) {
              event.preventDefault()
              submit(
                event.shiftKey && (event.ctrlKey || event.metaKey)
                  ? model.deliveryMode.value === 'steer'
                    ? 'queue'
                    : 'steer'
                  : undefined
              )
            }
          }}
        />
        <InputGroupAddon align="block-end" className="pod-chat-composer-tools">
          <div className="pod-chat-recipient-tools">
            <ChatAttachmentButton model={model.attachments} disabled={disabled || !!model.editing.value} />
            {existingAgent || agents.length === 1 ? (
              <span className="pod-chat-agent-name">{existingAgent ?? agents[0]?.displayName}</span>
            ) : agents.length > 1 ? (
              <Select
                value={agentUID || null}
                onValueChange={value => {
                  if (model.selectedAgentUID.value !== (value ?? '')) model.modelProfile.value = null
                  model.selectedAgentUID.value = value ?? ''
                }}
                disabled={sending}>
                <SelectTrigger aria-label={t('pod.chat.choose_agent')} size="sm" className="pod-chat-agent-picker">
                  <SelectValue placeholder={t('pod.chat.choose_agent')} />
                </SelectTrigger>
                <SelectContent align="start">
                  {agents.map(agent => (
                    <SelectItem key={agent.uid} value={agent.uid}>
                      {agent.displayName}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            ) : (
              <span />
            )}
            {agentUID && (
              <ModelControls
                agentUID={agentUID}
                conversationID={conversationID}
                draftProfile={model.modelProfile.value}
                onDraftProfileChange={profile => {
                  model.modelProfile.value = profile
                }}
                onRequiresQueue={required => {
                  if (required) model.deliveryMode.value = 'queue'
                }}
                activeSignalID={activeSignalID}
                disabled={disabled || !!model.editing.value}
              />
            )}
          </div>
          <div className="pod-chat-send-tools">
            {model.editing.value ? (
              <Button type="button" variant="ghost" size="xs" disabled={disabled} onClick={() => model.cancelEdit()}>
                {t('pod.chat.cancel_pending')}
              </Button>
            ) : followupRelevant ? (
              <Select
                value={model.deliveryMode.value}
                onValueChange={value => {
                  if (value === 'steer' || value === 'queue') model.deliveryMode.value = value
                }}
                disabled={disabled}>
                <SelectTrigger
                  aria-label={t('pod.chat.followup_mode')}
                  title={t(model.deliveryMode.value === 'steer' ? 'pod.chat.steer_hint' : 'pod.chat.queue_hint')}
                  size="sm"
                  className="pod-chat-mode-picker">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent align="end">
                  <SelectItem value="steer">{t('pod.chat.steer')}</SelectItem>
                  <SelectItem value="queue">{t('pod.chat.queue')}</SelectItem>
                </SelectContent>
              </Select>
            ) : null}
            {working && (
              <InputGroupButton
                type="button"
                variant="ghost"
                size="icon-sm"
                aria-label={t('pod.chat.stop')}
                title={t('pod.chat.stop_hint')}
                disabled={disabled}
                onClick={stop}>
                <RiStopFill aria-hidden />
              </InputGroupButton>
            )}
            <InputGroupButton
              type="submit"
              variant="outline"
              size="icon-sm"
              aria-label={
                sending ? t('pod.chat.sending') : model.editing.value ? t('pod.chat.save_pending') : t('pod.chat.send')
              }
              disabled={!canSubmit}>
              {model.editing.value ? <RiCheckLine aria-hidden /> : <RiArrowUpLine aria-hidden />}
            </InputGroupButton>
          </div>
        </InputGroupAddon>
      </InputGroup>
    </form>
  )
}

function MessageHistory({
  model,
  presentation,
  conversationID,
  history,
  messages,
  working,
  retryTime,
  activity,
  retryableMessageID,
  actions
}: {
  model: InstanceType<typeof ChatModel>
  presentation: ChatPresentation
  conversationID: string
  history: ReturnType<typeof useChatHistory>
  messages: DisplayMessage[]
  working: boolean
  retryTime?: string
  activity?: PodActivity
  retryableMessageID: string | null
  actions?: MessageActions
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
  useChatReading(model, presentation, stick, messageKeys)
  const committed = messages.filter(item => item.type === 'committed').map(item => item.message)
  const lastHuman = committed.findLast(message => message.authorType === 'human')
  return (
    <div className="pod-chat-history">
      <div
        ref={scrollRef}
        role="region"
        aria-label={t('pod.chat_history.label')}
        tabIndex={0}
        className="pod-chat-history-scroll">
        <div ref={contentRef} className="pod-chat-history-content">
          <OlderMessages history={history} scrollRef={scrollRef} />
          {messages.map(message => (
            <div key={messageID(message) ?? 'live'} data-chat-message-id={messageID(message)}>
              <ChatMessage
                item={message}
                conversationID={conversationID}
                edit={message.type === 'committed' && message.message.id === lastHuman?.id ? actions?.edit : undefined}
                regenerate={
                  message.type === 'committed' && message.message.id === retryableMessageID
                    ? actions?.regenerate
                    : undefined
                }
              />
            </div>
          ))}
          {activity && (activity.phase || activity.tools.length > 0) ? (
            <CurrentActivity activity={activity} />
          ) : working ? (
            <div role="status" className="flex items-center gap-2 text-[13px] text-fg-tertiary">
              <span aria-hidden className="size-1.5 rounded-full bg-current" />
              {retryTime ? t('pod.chat.retrying', { time: retryTime }) : t('pod.chat.replying')}
            </div>
          ) : null}
        </div>
      </div>
      {!isAtBottom ? (
        <Button
          className="absolute bottom-2 left-1/2 -translate-x-1/2 shadow-sm"
          variant="outline"
          size="sm"
          onClick={event => void scrollToBottom(reducedMotion || event.detail === 0 ? 'instant' : undefined)}>
          <RiArrowDownLine aria-hidden />
          {t('pod.chat.scroll_latest')}
        </Button>
      ) : null}
    </div>
  )
}

function CurrentActivity({ activity }: { activity: PodActivity }) {
  const { t } = useTranslation()
  const label = (item: PodActivityItem) =>
    item.label_key?.startsWith('conversations.delivery.reply.activity.')
      ? t(item.label_key, { ...item.label_bindings, defaultValue: t('pod.chat.replying') })
      : item.label || t('pod.chat.replying')
  return (
    <div role="status" aria-live="polite" className="space-y-1 text-[13px] text-fg-tertiary">
      {activity.phase ? <p>{label(activity.phase)}</p> : null}
      {activity.tools.map(tool => (
        <p key={tool.operation_id}>{label(tool)}</p>
      ))}
    </div>
  )
}

type CommittedMessage = Extract<DisplayMessage, { type: 'committed' }>['message']
type MessageActions = { edit(message: CommittedMessage): void; regenerate(message: CommittedMessage): void }

function ChatMessage({
  item,
  conversationID,
  edit,
  regenerate
}: {
  item: DisplayMessage
  conversationID: string
  edit?: MessageActions['edit']
  regenerate?: MessageActions['regenerate']
}) {
  const { t } = useTranslation()
  if (item.type === 'live') return <MarkdownBody className="pod-chat-agent-message" text={item.text} copyCode />
  if (item.type === 'committed' && item.message.kind === 'notice') {
    return (
      <div className="pod-chat-agent-message">
        <p className="whitespace-pre-wrap text-[13px] leading-5 text-fg-tertiary">{item.message.text}</p>
        {regenerate && <MessageCopy text="" regenerate={() => regenerate(item.message)} retry />}
      </div>
    )
  }
  const human = item.type === 'pending' || item.message.authorType === 'human'
  if (!human) {
    return (
      <div className="pod-chat-agent-message">
        <MarkdownBody text={item.message.text ?? ''} copyCode />
        <MessageCopy
          text={item.message.text ?? ''}
          regenerate={regenerate ? () => regenerate(item.message) : undefined}
        />
        <MessageArtifacts conversationID={conversationID} message={item.message} />
      </div>
    )
  }
  return (
    <div className="pod-chat-human-message">
      {item.message.text && (
        <div className={cn('pod-chat-human-text whitespace-pre-wrap', item.type === 'pending' && 'opacity-65')}>
          {item.message.text}
        </div>
      )}
      {item.type === 'pending' ? (
        <span className="text-xs text-fg-tertiary">
          {t(item.message.state === 'failed' ? 'pod.chat.send_failed' : 'pod.chat.sending')}
        </span>
      ) : null}
      {item.type === 'committed' && <MessageArtifacts conversationID={conversationID} message={item.message} />}
      {item.type === 'committed' && (
        <MessageCopy text={item.message.text ?? ''} edit={edit ? () => edit(item.message) : undefined} />
      )}
    </div>
  )
}

function MessageCopy({
  text,
  edit,
  regenerate,
  retry
}: {
  text: string
  edit?(): void
  regenerate?(): void
  retry?: boolean
}) {
  const { t } = useTranslation()
  return (
    <div className="pod-chat-message-actions">
      {edit && (
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={t('pod.chat.edit_last')}
          title={t('pod.chat.edit_last')}
          onClick={edit}>
          <RiEditLine aria-hidden />
        </Button>
      )}
      {regenerate && (
        <>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label={t(retry ? 'pod.chat.retry_reply' : 'pod.chat.regenerate')}
            title={t(retry ? 'pod.chat.retry_reply' : 'pod.chat.regenerate')}
            onClick={regenerate}>
            <RiRestartLine aria-hidden />
          </Button>
          <span className="pod-chat-action-hint">{t('pod.chat.retry_keeps_artifacts')}</span>
        </>
      )}
      {text && (
        <Button
          variant="ghost"
          size="icon-xs"
          aria-label={t('pod.chat.copy_message')}
          title={t('pod.chat.copy_message')}
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(text)
              toast.success(t('pod.chat.message_copied'))
            } catch {
              toast.error(t('pod.chat.copy_failed'))
            }
          }}>
          <RiFileCopyLine aria-hidden />
        </Button>
      )}
    </div>
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
  const { t, i18n } = useTranslation()
  const payload = error instanceof InternalAPIError ? error.payload : error
  const code =
    requestErrorCode(payload) ??
    (typeof (payload as { error?: unknown })?.error === 'string' ? (payload as { error: string }).error : undefined)
  const known = code && i18n.exists(`pod.chat.errors.${code}`)
  return (
    <div role="alert" className="space-y-2 text-[13px] leading-5">
      <p className="text-destructive">{known ? t(`pod.chat.errors.${code}`) : requestErrorMessage(error)}</p>
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
