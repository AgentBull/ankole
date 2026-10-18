import { podLocation } from '../common/browser-context'
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
  cn
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiArrowDownLine, RiArrowUpLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import { useStickToBottom } from 'use-stick-to-bottom'
import { InternalAPIError } from '../common/internal-api-client'
import { MarkdownBody } from '../common/markdown-body'
import { requestErrorCode, requestErrorMessage } from '../common/request-errors'
import {
  agentsQuery,
  conversationNotFound,
  conversationQuery,
  postMessage,
  podKeys,
  type MessageSubmission,
  type PodActivity,
  type PodActivityItem,
  type PodAgent
} from './api'
import { ChatModel, mergeMessages, shouldSendOnEnter, type DisplayMessage } from './state/chat'
import { refreshConversationQueries } from './query-cache'
import { useConversationEvents } from './use-conversation-events'

export function ChatRoute() {
  const { conversationID } = useParams()
  return <ChatPage key={conversationID ?? 'new'} conversationID={conversationID} />
}

function ChatPage({ conversationID }: { conversationID?: string }) {
  useSignals()
  const { t, i18n } = useTranslation()
  const navigate = useNavigate()
  const client = useQueryClient()
  const model = useModel(ChatModel)
  const agents = useQuery({ ...agentsQuery, enabled: !conversationID })
  const query = conversationQuery(conversationID ?? '')
  const detail = useQuery({
    ...query,
    queryFn: async () => {
      const observation = model.activityRead()
      const detail = await query.queryFn()
      model.observeActivity(detail.status.activity, observation)
      return detail
    },
    enabled: !!conversationID && !model.gone.value
  })
  const send = useMutation({
    mutationFn: (submission: MessageSubmission) => postMessage(submission, !conversationID),
    onSuccess: (data, submission) => {
      model.accepted(submission)
      void refreshConversationQueries(client, data.conversation.id)
    },
    onError: failure => {
      model.failed(failure)
      if (conversationID && conversationNotFound(failure)) {
        model.markGone()
        client.removeQueries({ queryKey: podKeys.detail(conversationID), exact: true })
        void refreshConversationQueries(client, conversationID)
        return
      }
      void client.invalidateQueries({ queryKey: podKeys.agents })
      if (conversationID) void refreshConversationQueries(client, conversationID)
    }
  })
  const data = detail.data
  const availableAgents = agents.data?.agents ?? []
  const selection = model.selectedAgentUID.value
  const selectedAgentUID = availableAgents.some(agent => agent.uid === selection) ? selection : ''
  const agentUID =
    data?.conversation.agent.uid ?? (availableAgents.length === 1 ? availableAgents[0]!.uid : selectedAgentUID)
  const sending = send.isPending || model.pending.value?.state === 'sending'
  const disabled = sending || (conversationID ? !data?.conversation.agent.active : !agentUID || agents.isError)
  const submit = () => {
    if (disabled || !model.hasText.value) return
    send.mutate(
      model.submit(conversationID, agentUID, () => crypto.randomUUID()),
      {
        onSuccess: data => {
          if (!conversationID) void navigate(podLocation(`/conversations/${data.conversation.id}`))
        }
      }
    )
  }

  const gone = model.gone.value || conversationNotFound(detail.error)
  useConversationEvents(gone ? undefined : conversationID, model)
  useEffect(() => {
    if (data) {
      model.reconcile(data.messages)
    }
  }, [data, model])
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
      disabled={disabled}
      sending={sending}
      submit={submit}
    />
  )
  const failure = model.error.value
  const retry = (
    <Button size="sm" variant="outline" onClick={submit} disabled={disabled}>
      {t('pod.chat.retry_send')}
    </Button>
  )

  if (!conversationID) {
    return (
      <main className="flex h-full min-h-0 flex-col justify-center px-4 pb-12 md:px-8">
        <div className="mx-auto w-full max-w-3xl space-y-6">
          <h1 className="text-center text-2xl font-medium tracking-tight">{t('pod.chat.new_title')}</h1>
          {agents.isPending ? (
            <p role="status" className="text-center text-[13px] text-fg-tertiary">
              {t('pod.chat.loading_agents')}
            </p>
          ) : null}
          {agents.isError ? <RequestFailure error={agents.error} retry={() => void agents.refetch()} /> : null}
          {!agents.isPending && !agents.isError && !availableAgents.length ? (
            <p className="text-center text-[13px] text-fg-tertiary">{t('pod.chat.no_agents')}</p>
          ) : null}
          {failure ? <RequestFailure error={failure} action={retry} sendFailure /> : null}
          {composer}
        </div>
      </main>
    )
  }
  if (gone) return <ConversationGone />
  if (!data) {
    return (
      <main className="mx-auto flex h-full w-full max-w-3xl items-center justify-center px-4">
        {detail.isError ? (
          <RequestFailure error={detail.error} retry={() => void detail.refetch()} />
        ) : (
          <p role="status" className="text-[13px] text-fg-tertiary">
            {t('pod.chat.loading_history')}
          </p>
        )}
      </main>
    )
  }
  const messages = mergeMessages(data.messages, model.pending.value, model.live.value)
  const working = data.status.state !== 'idle' || !!model.live.value
  const retryTime = data.status.retryAt
    ? new Date(data.status.retryAt).toLocaleTimeString(i18n.language, { hour: '2-digit', minute: '2-digit' })
    : undefined

  return (
    <main className="flex h-full min-h-0 flex-col">
      <h1 className="sr-only">{data.conversation.title}</h1>
      <MessageHistory messages={messages} working={working} retryTime={retryTime} activity={model.activity.value} />
      <div className="mx-auto w-full max-w-3xl shrink-0 space-y-3 px-4 pt-3 pb-5 md:px-6">
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
    </main>
  )
}

function ConversationGone() {
  const { t } = useTranslation()
  return (
    <main className="mx-auto flex h-full w-full max-w-3xl flex-col items-center justify-center gap-4 px-4">
      <p role="alert" className="text-[13px] text-fg-tertiary">
        {t('pod.chat.errors.conversation_not_found')}
      </p>
      <Button render={<Link to="/" />} nativeButton={false} variant="outline">
        {t('pod.chat.new_conversation')}
      </Button>
    </main>
  )
}

function Composer({
  model,
  agents,
  agentUID,
  existingAgent,
  disabled,
  sending,
  submit
}: {
  model: InstanceType<typeof ChatModel>
  agents: PodAgent[]
  agentUID: string
  existingAgent?: string
  disabled: boolean
  sending: boolean
  submit: () => void
}) {
  useSignals()
  const { t } = useTranslation()
  return (
    <form
      onSubmit={event => {
        event.preventDefault()
        submit()
      }}>
      <InputGroup className="px-3">
        <InputGroupTextarea
          aria-label={t('pod.chat.message_label')}
          autoFocus
          className="max-h-52 min-h-20 px-0 text-sm"
          disabled={disabled && (sending || !!existingAgent || agents.length === 0)}
          placeholder={t('pod.chat.placeholder')}
          rows={2}
          value={model.draft.value}
          onChange={event => {
            model.draft.value = event.target.value
          }}
          onKeyDown={event => {
            if (
              shouldSendOnEnter({
                key: event.key,
                shiftKey: event.shiftKey,
                isComposing: event.nativeEvent.isComposing,
                keyCode: event.nativeEvent.keyCode
              })
            ) {
              event.preventDefault()
              submit()
            }
          }}
        />
        <InputGroupAddon align="block-end" className="justify-between gap-3 pb-2">
          {existingAgent || agents.length === 1 ? (
            <span className="min-w-0 truncate text-[13px] text-fg-tertiary">
              {existingAgent ?? agents[0]?.displayName}
            </span>
          ) : agents.length > 1 ? (
            <Select
              value={agentUID || null}
              onValueChange={value => {
                model.selectedAgentUID.value = value ?? ''
              }}
              disabled={sending}>
              <SelectTrigger
                aria-label={t('pod.chat.choose_agent')}
                size="sm"
                className="max-w-64 border-transparent bg-transparent px-1 text-[13px]">
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
          <InputGroupButton
            type="submit"
            variant="default"
            size="icon-sm"
            aria-label={sending ? t('pod.chat.sending') : t('pod.chat.send')}
            disabled={disabled || !model.hasText.value}>
            <RiArrowUpLine aria-hidden />
          </InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    </form>
  )
}

function MessageHistory({
  messages,
  working,
  retryTime,
  activity
}: {
  messages: DisplayMessage[]
  working: boolean
  retryTime?: string
  activity?: PodActivity
}) {
  const { t } = useTranslation()
  const { scrollRef, contentRef, isAtBottom, scrollToBottom } = useStickToBottom({
    initial: 'instant',
    resize: 'smooth'
  })
  return (
    <div className="relative min-h-0 flex-1">
      <div ref={scrollRef} className="h-full overflow-y-auto">
        <div ref={contentRef} className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 pt-4 pb-6 md:px-6">
          {messages.map(message => (
            <ChatMessage
              key={
                message.type === 'committed'
                  ? message.message.id
                  : message.type === 'pending'
                    ? message.message.messageID
                    : 'live'
              }
              item={message}
            />
          ))}
          {activity && (activity.phase || activity.tools.length > 0) ? (
            <CurrentActivity activity={activity} />
          ) : working ? (
            <div role="status" className="flex items-center gap-2 text-[13px] text-fg-tertiary">
              <span aria-hidden className="size-1.5 animate-pulse rounded-full bg-current motion-reduce:animate-none" />
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
          onClick={() => void scrollToBottom()}>
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

function ChatMessage({ item }: { item: DisplayMessage }) {
  const { t } = useTranslation()
  if (item.type === 'live') return <MarkdownBody text={item.text} />
  if (item.type === 'committed' && item.message.kind === 'notice') {
    return <p className="whitespace-pre-wrap text-[13px] leading-5 text-fg-tertiary">{item.message.text}</p>
  }
  const human = item.type === 'pending' || item.message.authorType === 'human'
  if (!human) return <MarkdownBody text={item.message.text} />
  return (
    <div className="flex flex-col items-end gap-1">
      <div
        className={cn(
          'max-w-[85%] rounded-xl bg-muted px-4 py-2.5 text-sm leading-6 break-words whitespace-pre-wrap',
          item.type === 'pending' && 'opacity-65'
        )}>
        {item.message.text}
      </div>
      {item.type === 'pending' ? (
        <span className="text-xs text-fg-tertiary">
          {t(item.message.state === 'failed' ? 'pod.chat.send_failed' : 'pod.chat.sending')}
        </span>
      ) : null}
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
  const { t } = useTranslation()
  const payload = error instanceof InternalAPIError ? error.payload : error
  const code =
    requestErrorCode(payload) ??
    (typeof (payload as { error?: unknown })?.error === 'string' ? (payload as { error: string }).error : undefined)
  const known =
    code &&
    [
      'agent_unavailable',
      'conversation_not_found',
      'conversation_conflict',
      'invalid_id',
      'invalid_text',
      'invalid_request'
    ].includes(code)
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
