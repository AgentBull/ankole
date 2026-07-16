import { Badge, Button, Skeleton, TableCell, TableRow } from '@ankole/uikit'
import { RiArrowLeftLine, RiArrowRightLine, RiFunctionLine, RiInboxLine } from '@remixicon/react'
import { match } from '@pleisto/active-support'
import { useQuery } from '@tanstack/react-query'
import { type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { ErrorBlock, formatConsoleDate } from '../console-primitives'
import { PageHeader, ResourceListPage, ResourceSearch, StatusIndicator } from '../console-shell'
import {
  ankoleWebAiGatewayConversationControllerIndexOptions as ankoleWebAIGatewayConversationControllerIndexOptions,
  ankoleWebAiGatewayConversationControllerMessagesOptions as ankoleWebAIGatewayConversationControllerMessagesOptions,
  ankoleWebAiGatewayConversationControllerShowOptions as ankoleWebAIGatewayConversationControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type {
  AiGatewayConversationItem as AIGatewayConversationItem,
  AiGatewayMessageItem as AIGatewayMessageItem
} from '../api/generated/types.gen'

type ResponseItem = Record<string, unknown>

/**
 * Conversations list page — installation-wide browser for AIGateway conversations.
 * The list is read-only; selecting a row opens the detail route that renders the
 * message thread.
 */
export function ConversationsListPage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const subjectFilter = searchParams.get('subject') ?? ''
  const cursor = searchParams.get('cursor') ?? undefined
  const activeFilter = searchParams.get('active')

  const list = useQuery(
    ankoleWebAIGatewayConversationControllerIndexOptions({
      query: {
        subject: subjectFilter.trim() || undefined,
        active: activeFilter === 'true' ? true : activeFilter === 'false' ? false : undefined,
        cursor,
        limit: 50
      }
    })
  )

  const conversations = list.data?.conversations ?? []
  const nextCursor = list.data?.next_cursor ?? undefined

  const setSubjectFilter = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('subject', value)
    else next.delete('subject')
    next.delete('cursor')
    setSearchParams(next, { replace: true })
  }

  const toggleActive = () => {
    const next = new URLSearchParams(searchParams)
    const current = next.get('active')
    const value = current === 'true' ? 'false' : current === 'false' ? null : 'true'
    if (value === null) next.delete('active')
    else next.set('active', value)
    next.delete('cursor')
    setSearchParams(next, { replace: true })
  }

  const goCursor = (value: string | undefined) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('cursor', value)
    else next.delete('cursor')
    setSearchParams(next)
  }

  return (
    <ResourceListPage
      title={t('console.conversations.title')}
      description={t('console.conversations.description')}
      columns={[
        t('console.conversations.subject'),
        t('console.conversations.key'),
        t('console.conversations.status'),
        t('console.conversations.updated')
      ]}
      isLoading={list.isLoading}
      isEmpty={conversations.length === 0}
      isFiltered={Boolean(subjectFilter.trim()) || activeFilter !== null}
      emptyTitle={t('console.conversations.empty_title')}
      emptyDescription={t('console.conversations.empty_description')}
      error={list.error}
      toolbar={
        <div className="flex flex-wrap items-center gap-2">
          <ResourceSearch
            label={t('console.conversations.subject_filter')}
            placeholder={t('console.conversations.subject_filter')}
            value={subjectFilter}
            onChange={setSubjectFilter}
          />
          <Button type="button" size="sm" variant={activeFilter ? 'default' : 'outline'} onClick={toggleActive}>
            {activeFilter === 'true'
              ? t('console.conversations.filter_active_only')
              : activeFilter === 'false'
                ? t('console.conversations.filter_ended_only')
                : t('console.conversations.filter_all')}
          </Button>
        </div>
      }
      footer={
        nextCursor ? (
          <div className="flex justify-end py-2">
            <Button type="button" size="sm" variant="outline" onClick={() => goCursor(nextCursor)}>
              {t('console.conversations.next_page')}
              <RiArrowRightLine />
            </Button>
          </div>
        ) : null
      }>
      {conversations.map(conversation => (
        <ConversationRow key={conversation.id} conversation={conversation} />
      ))}
    </ResourceListPage>
  )
}

function ConversationRow({ conversation }: { conversation: AIGatewayConversationItem }) {
  const { t } = useTranslation()
  const active = conversation.ended_at == null

  return (
    <TableRow>
      <TableCell className="font-mono text-xs">
        <Link className="text-foreground hover:text-primary hover:underline" to={encodeURIComponent(conversation.id)}>
          {conversation.subject_uid}
        </Link>
      </TableCell>
      <TableCell className="max-w-[24rem] truncate font-mono text-xs">{conversation.conversation_key}</TableCell>
      <TableCell>
        <StatusIndicator tone={active ? 'positive' : 'neutral'}>
          {active ? t('console.conversations.status_active') : t('console.conversations.status_ended')}
        </StatusIndicator>
      </TableCell>
      <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
        {formatConsoleDate(conversation.updated_at)}
      </TableCell>
    </TableRow>
  )
}

/**
 * Conversation detail page — the conversation metadata plus its full message
 * thread rendered as a chat-style bubble timeline. Read-only; no polling.
 */
export function ConversationDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { conversationID = '' } = useParams()
  const [searchParams, setSearchParams] = useSearchParams()
  const cursor = searchParams.get('cursor') ?? undefined

  const conversation = useQuery({
    ...ankoleWebAIGatewayConversationControllerShowOptions({
      path: { conversation_id: conversationID }
    }),
    enabled: Boolean(conversationID),
    retry: false
  })

  const messages = useQuery({
    ...ankoleWebAIGatewayConversationControllerMessagesOptions({
      path: { conversation_id: conversationID },
      query: { cursor, limit: 200 }
    }),
    enabled: Boolean(conversationID),
    retry: false
  })

  const detail = conversation.data?.conversation
  const thread = messages.data?.messages ?? []
  const nextCursor = messages.data?.next_cursor ?? undefined

  const goCursor = (value: string | undefined) => {
    const next = new URLSearchParams(searchParams)
    if (value) next.set('cursor', value)
    else next.delete('cursor')
    setSearchParams(next)
  }

  if (conversation.error || (!conversation.isLoading && !detail)) {
    return (
      <div className="grid gap-4">
        <div className="flex items-center justify-between">
          <Button type="button" size="sm" variant="ghost" onClick={() => navigate('/conversations')}>
            <RiArrowLeftLine />
            {t('console.conversations.back')}
          </Button>
        </div>
        <ErrorBlock error={conversation.error ?? new Error(t('console.conversations.not_found'))} />
      </div>
    )
  }

  return (
    <div className="grid gap-6">
      <div className="flex items-center justify-between">
        <Button type="button" size="sm" variant="ghost" onClick={() => navigate('/conversations')}>
          <RiArrowLeftLine />
          {t('console.conversations.back')}
        </Button>
      </div>

      <PageHeader
        title={detail?.conversation_key ?? t('console.conversations.detail_title')}
        description={detail ? `${detail.subject_uid} · ${detail.id}` : undefined}
      />

      {conversation.isLoading || !detail ? (
        <Skeleton className="h-32 w-full" />
      ) : (
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 border border-border bg-card p-4 text-sm">
          <DetailField label={t('console.conversations.subject')} value={<code>{detail.subject_uid}</code>} />
          <DetailField
            label={t('console.conversations.status')}
            value={
              <StatusIndicator tone={detail.ended_at == null ? 'positive' : 'neutral'}>
                {detail.ended_at == null
                  ? t('console.conversations.status_active')
                  : t('console.conversations.status_ended')}
              </StatusIndicator>
            }
          />
          <DetailField label={t('console.conversations.key')} value={<code>{detail.conversation_key}</code>} />
          <DetailField label={t('console.conversations.ended_at')} value={formatConsoleDate(detail.ended_at)} />
          <DetailField label={t('console.conversations.created')} value={formatConsoleDate(detail.inserted_at)} />
          <DetailField label={t('console.conversations.updated')} value={formatConsoleDate(detail.updated_at)} />
          <DetailField label={t('console.conversations.metadata')} value={<RawJSON value={detail.metadata} />} wide />
        </dl>
      )}

      <section className="grid gap-3">
        <div className="flex items-center justify-between">
          <h3 className="font-medium">{t('console.conversations.messages')}</h3>
          {messages.isLoading ? (
            <span className="text-xs text-muted-foreground">{t('console.conversations.loading')}</span>
          ) : (
            <span className="text-xs text-muted-foreground">
              {t('console.conversations.message_count', { count: thread.length })}
            </span>
          )}
        </div>

        {messages.error ? (
          <ErrorBlock error={messages.error} />
        ) : messages.isLoading ? (
          <Skeleton className="h-64 w-full" />
        ) : thread.length === 0 ? (
          <div className="flex items-center gap-3 border border-border bg-card p-8 text-sm text-muted-foreground">
            <RiInboxLine className="size-5" />
            {t('console.conversations.no_messages')}
          </div>
        ) : (
          <MessageThread messages={thread} />
        )}

        {nextCursor ? (
          <div className="flex justify-end">
            <Button type="button" size="sm" variant="outline" onClick={() => goCursor(nextCursor)}>
              {t('console.conversations.next_page')}
              <RiArrowRightLine />
            </Button>
          </div>
        ) : null}
      </section>
    </div>
  )
}

/**
 * Chat-style message thread. User/assistant text items render as left/right
 * bubbles; tool items (function_call, function_call_output, reasoning) render
 * as full-width labeled compact blocks; checkpoints render as a single label.
 * The raw JSON is always reachable via the <RawJSON> fallback so no information
 * is lost for unfamiliar ResponseItem variants.
 */
function MessageThread({ messages }: { messages: AIGatewayMessageItem[] }) {
  return (
    <div className="grid gap-4">
      {messages.map(message => (
        <MessageRow key={message.id} message={message} />
      ))}
    </div>
  )
}

function MessageRow({ message }: { message: AIGatewayMessageItem }) {
  const { t } = useTranslation()
  const role = message.role

  // Checkpoint rows reference a compaction artifact; show the header plus the
  // raw content/metadata so the artifact reference stays inspectable.
  if (message.type === 'checkpoint') {
    return (
      <div className="grid gap-1 px-2 py-1 text-xs text-muted-foreground">
        <div className="flex items-center gap-2">
          <Badge variant="secondary">checkpoint</Badge>
          <span className="font-mono">{message.id}</span>
          <span>· {formatConsoleDate(message.inserted_at)}</span>
        </div>
        <RawJSON value={message.content} />
      </div>
    )
  }

  const text = extractOutputText(message.content)

  // Tool rows are not conversational bubbles; render as labeled compact blocks.
  if (role === 'tool' || hasToolItems(message.content)) {
    return (
      <article className="grid gap-2 border border-border bg-muted/40 p-3 text-xs">
        <header className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <RiFunctionLine className="size-3.5 text-muted-foreground" />
            <Badge variant="secondary">{role ?? 'tool'}</Badge>
          </div>
          <MessageMeta message={message} />
        </header>
        <ToolItems content={message.content} fallbackText={text} />
      </article>
    )
  }

  // Conversational text bubbles.
  const isUser = role === 'user'

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div className={`grid max-w-2xl gap-1 ${isUser ? 'items-end' : 'items-start'}`}>
        <div className="flex items-center gap-2 px-1 text-xs text-muted-foreground">
          <Badge variant="secondary">{role ?? 'message'}</Badge>
          <MessageStatus message={message} />
        </div>
        <div className={`px-4 py-2 text-sm text-foreground ${isUser ? 'border border-border bg-card' : 'bg-muted'}`}>
          {text ? <p className="whitespace-pre-wrap break-words">{text}</p> : <RawJSON value={message.content} />}
        </div>
        <span className="px-1 text-xs text-muted-foreground">{formatConsoleDate(message.inserted_at)}</span>
      </div>
    </div>
  )
}

function MessageMeta({ message }: { message: AIGatewayMessageItem }) {
  return (
    <div className="flex items-center gap-2 text-muted-foreground">
      <MessageStatus message={message} />
      <span>· {formatConsoleDate(message.inserted_at)}</span>
    </div>
  )
}

function MessageStatus({ message }: { message: AIGatewayMessageItem }) {
  const { t } = useTranslation()
  // `complete` is the common case; rendering a green check on every row is noise,
  // so only surface the badge for states an operator needs to notice.
  const tone = match(message.status)
    .with('complete', () => null)
    .with('error', () => 'danger' as const)
    .with('retracted', () => 'danger' as const)
    .with('generating', () => 'info' as const)
    .otherwise(() => 'neutral' as const)
  if (tone === null) return null
  return <StatusIndicator tone={tone}>{t(`console.conversations.message_status.${message.status}`)}</StatusIndicator>
}

function ToolItems({ content, fallbackText }: { content: ResponseItem[]; fallbackText: string }) {
  const toolItems = content.filter(isToolItem)

  if (toolItems.length === 0) {
    return <RawJSON value={fallbackText || content} />
  }

  return (
    <div className="grid gap-2">
      {toolItems.map((item, index) => (
        <div key={index} className="grid gap-1 bg-background p-2">
          <div className="flex items-center gap-2">
            <Badge variant="secondary">{String(item.type ?? 'item')}</Badge>
            {typeof item.name === 'string' ? <span className="font-mono text-xs">{item.name}</span> : null}
            {typeof item.call_id === 'string' ? (
              <span className="font-mono text-xs text-muted-foreground">{item.call_id}</span>
            ) : null}
          </div>
          <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-sans text-xs">
            {truncate(toolItemText(item), 4_000)}
          </pre>
        </div>
      ))}
    </div>
  )
}

function RawJSON({ value }: { value: unknown }) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2)
  return (
    <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">
      {truncate(text, 8_000)}
    </pre>
  )
}

function DetailField({ label, value, wide = false }: { label: string; value: ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? 'col-span-2 grid gap-1' : 'grid gap-1'}>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="break-words">{value}</dd>
    </div>
  )
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}

function extractOutputText(content: ResponseItem[]): string {
  const parts: string[] = []

  for (const item of content) {
    if (item.type === 'message') {
      const inner = Array.isArray(item.content) ? item.content : []
      for (const part of inner) {
        if (part && typeof part === 'object' && typeof part.text === 'string') {
          parts.push(part.text)
        }
      }
    } else if (typeof item.text === 'string') {
      parts.push(item.text)
    }
  }

  return parts.join('\n').trim()
}

function hasToolItems(content: ResponseItem[]): boolean {
  return content.some(isToolItem)
}

function isToolItem(item: ResponseItem): boolean {
  const type = item.type
  return type === 'function_call' || type === 'function_call_output' || type === 'reasoning'
}

function toolItemText(item: ResponseItem): string {
  if (typeof item.arguments === 'string') return item.arguments
  if (typeof item.output === 'string') return item.output
  if (item.content !== undefined) {
    return typeof item.content === 'string' ? item.content : JSON.stringify(item.content, null, 2)
  }
  return JSON.stringify(item, null, 2)
}
