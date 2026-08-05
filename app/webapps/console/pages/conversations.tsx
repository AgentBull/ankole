import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
  Badge,
  Button,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  TableCell,
  TableRow,
  cn
} from '@ankole/uikit'
import { RiArrowLeftLine, RiChat3Line, RiFunctionLine, RiInboxLine } from '@remixicon/react'
import { match } from '@agentbull/active-support'
import { useQuery } from '@tanstack/react-query'
import { type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { PageStack } from '../console-page'
import { ErrorBlock, formatConsoleDate } from '../console-primitives'
import { MarkdownBody } from '../markdown-body'
import { StatusIndicator } from '../console-form'
import { CursorPagination, ResourceListPage, ResourceSearch } from '../console-list-page'
import {
  cursorPageNumber,
  hasPreviousCursor,
  nextCursorParams,
  previousCursorParams,
  resetCursorParams
} from '../state/cursor-pagination'
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
  // Stub conversations (fewer than two messages — no exchange recorded) are
  // hidden by default; `min_messages=0` opts back into the full list.
  const showAll = searchParams.get('min_messages') === '0'

  const list = useQuery(
    ankoleWebAIGatewayConversationControllerIndexOptions({
      query: {
        subject: subjectFilter.trim() || undefined,
        active: activeFilter === 'true' ? true : activeFilter === 'false' ? false : undefined,
        min_messages: showAll ? undefined : 2,
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
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  const toggleActive = () => {
    const next = new URLSearchParams(searchParams)
    const current = next.get('active')
    const value = current === 'true' ? 'false' : current === 'false' ? null : 'true'
    if (value === null) next.delete('active')
    else next.set('active', value)
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  const setMessageFilter = (value: string) => {
    const next = new URLSearchParams(searchParams)
    if (value === 'all') next.set('min_messages', '0')
    else next.delete('min_messages')
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  const isFiltered = Boolean(subjectFilter.trim()) || activeFilter !== null
  const clearFilters = () => {
    const next = new URLSearchParams(searchParams)
    next.delete('subject')
    next.delete('active')
    setSearchParams(resetCursorParams(next), { replace: true })
  }

  return (
    <ResourceListPage
      title={t('console.conversations.title')}
      description={t('console.conversations.description')}
      columns={[
        t('console.conversations.name'),
        t('console.conversations.subject'),
        t('console.conversations.messages'),
        t('console.conversations.status'),
        t('console.conversations.updated')
      ]}
      isLoading={list.isLoading}
      isEmpty={conversations.length === 0}
      isFiltered={isFiltered}
      onClearFilters={clearFilters}
      emptyTitle={t('console.conversations.empty_title')}
      emptyIcon={<RiChat3Line aria-hidden />}
      emptyDescription={
        isFiltered || showAll
          ? t('console.conversations.empty_description')
          : t('console.conversations.empty_min_messages_description')
      }
      error={list.error}
      count={conversations.length}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.conversations.subject_filter')}
          placeholder={t('console.conversations.subject_filter')}
          value={subjectFilter}
          onChange={setSubjectFilter}
          filters={
            <>
              <Button type="button" size="sm" variant={activeFilter ? 'default' : 'outline'} onClick={toggleActive}>
                {activeFilter === 'true'
                  ? t('console.conversations.filter_active_only')
                  : activeFilter === 'false'
                    ? t('console.conversations.filter_ended_only')
                    : t('console.conversations.filter_all')}
              </Button>
              <Select
                value={showAll ? 'all' : 'with_messages'}
                onValueChange={value => setMessageFilter(value ?? 'with_messages')}>
                <SelectTrigger size="sm" aria-label={t('console.conversations.filter_with_messages')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="with_messages">{t('console.conversations.filter_with_messages')}</SelectItem>
                  <SelectItem value="all">{t('console.conversations.filter_all_conversations')}</SelectItem>
                </SelectContent>
              </Select>
            </>
          }
        />
      }
      footer={
        <CursorPagination
          page={cursorPageNumber(searchParams)}
          hasPrevious={hasPreviousCursor(searchParams)}
          nextCursor={nextCursor}
          resultCount={conversations.length}
          onPrevious={() => setSearchParams(previousCursorParams(searchParams))}
          onNext={cursor => setSearchParams(nextCursorParams(searchParams, cursor))}
        />
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
      <TableCell>
        <div className="grid min-w-0 max-w-md gap-0.5">
          <div className="flex min-w-0 items-center gap-1.5">
            <Link
              className={cn(
                'truncate text-foreground hover:text-link hover:underline',
                conversation.display_name ? 'font-medium' : 'font-mono text-xs'
              )}
              to={encodeURIComponent(conversation.id)}>
              {conversation.display_name ?? conversation.conversation_key}
            </Link>
            <ConversationKindTags conversation={conversation} />
          </div>
          {conversation.display_name ? (
            <span className="truncate font-mono text-xs text-muted-foreground">{conversation.conversation_key}</span>
          ) : null}
        </div>
      </TableCell>
      <TableCell className="font-mono text-xs">{conversation.subject_uid}</TableCell>
      <TableCell className="text-right text-sm tabular-nums">
        <span className={conversation.message_count === 0 ? 'text-muted-foreground' : undefined}>
          {conversation.message_count}
        </span>
      </TableCell>
      <TableCell>
        <span className="inline-flex items-center gap-1.5 text-sm">
          <span className={cn('size-1.5 rounded-full', active ? 'bg-success' : 'bg-gray-40')} aria-hidden />
          <span className={active ? undefined : 'text-muted-foreground'}>
            {active ? t('console.conversations.status_active') : t('console.conversations.status_ended')}
          </span>
        </span>
      </TableCell>
      <TableCell className="whitespace-nowrap text-xs text-muted-foreground">
        {formatConsoleDate(conversation.updated_at)}
      </TableCell>
    </TableRow>
  )
}

/**
 * Room-type tags disambiguating rows that share one display name: the room
 * kind for non-signal conversations (Dreaming run, background job, managed
 * API session), and for signal rooms the DM/group kind plus the owning
 * adapter. `custom` keys and `unknown` channel kinds get no tag.
 */
function ConversationKindTags({ conversation }: { conversation: AIGatewayConversationItem }) {
  const { t } = useTranslation()

  return (
    <>
      {conversation.kind !== 'signal' && conversation.kind !== 'custom' ? (
        <Badge variant="secondary" className="shrink-0">
          {t(`console.conversations.kind.${conversation.kind}`)}
        </Badge>
      ) : null}
      {conversation.channel_kind && conversation.channel_kind !== 'unknown' ? (
        <Badge variant="outline" className="shrink-0">
          {t(`console.conversations.channel_kind.${conversation.channel_kind}`)}
        </Badge>
      ) : null}
      {conversation.signal_adapter ? (
        <Badge variant="outline" className="shrink-0 font-mono">
          {conversation.signal_adapter}
        </Badge>
      ) : null}
    </>
  )
}

/**
 * Conversation detail page — the conversation metadata plus its full message
 * thread. Read-only; no polling. The layout follows the console's Carbon
 * conventions: a constrained reading column, a hairline definition-list grid
 * for the resource facts, and a single left-aligned message stream where
 * conversational text renders as Markdown and tool traffic renders as
 * structured tiles.
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

  if (conversation.error || (!conversation.isLoading && !detail)) {
    return (
      <PageStack className="max-w-5xl">
        <BackLink label={t('console.conversations.back')} onClick={() => navigate('/conversations')} />
        <ErrorBlock error={conversation.error ?? new Error(t('console.conversations.not_found'))} />
      </PageStack>
    )
  }

  return (
    <PageStack className="max-w-5xl">
      <BackLink label={t('console.conversations.back')} onClick={() => navigate('/conversations')} />

      {conversation.isLoading || !detail ? (
        <Skeleton className="h-40 w-full" />
      ) : (
        <>
          <header className="grid gap-3 border-b border-border pb-6">
            <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
              <h2 className="min-w-0 break-all text-xl leading-8 font-semibold tracking-normal text-foreground">
                {detail.display_name ?? detail.conversation_key}
              </h2>
              <StatusIndicator tone={detail.ended_at == null ? 'positive' : 'neutral'}>
                {detail.ended_at == null
                  ? t('console.conversations.status_active')
                  : t('console.conversations.status_ended')}
              </StatusIndicator>
              <ConversationKindTags conversation={detail} />
            </div>
            <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-muted-foreground">
              {detail.display_name ? (
                <>
                  <span className="break-all font-mono text-xs">{detail.conversation_key}</span>
                  <span aria-hidden>·</span>
                </>
              ) : null}
              <span className="break-all">{detail.subject_uid}</span>
              <span aria-hidden>·</span>
              <span className="break-all font-mono text-xs">{detail.id}</span>
            </p>
          </header>

          <section className="grid gap-3" aria-label={t('console.conversations.details')}>
            <h3 className="text-base font-semibold">{t('console.conversations.details')}</h3>
            <dl className="grid grid-cols-1 gap-px border border-border bg-border sm:grid-cols-2 lg:grid-cols-3">
              <DetailField label={t('console.conversations.subject')} value={detail.subject_uid} mono />
              <DetailField label={t('console.conversations.key')} value={detail.conversation_key} mono />
              <DetailField label="ID" value={detail.id} mono />
              <DetailField label={t('console.conversations.messages')} value={detail.message_count} />
              <DetailField label={t('console.conversations.created')} value={formatConsoleDate(detail.inserted_at)} />
              <DetailField label={t('console.conversations.ended_at')} value={formatConsoleDate(detail.ended_at)} />
              <DetailField label={t('console.conversations.updated')} value={formatConsoleDate(detail.updated_at)} />
            </dl>
            {Object.keys(detail.metadata).length > 0 ? (
              <Accordion className="border border-border bg-card px-4">
                <AccordionItem value="metadata">
                  <AccordionTrigger className="py-3">{t('console.conversations.metadata')}</AccordionTrigger>
                  <AccordionContent>
                    <CodeBlock>{JSON.stringify(detail.metadata, null, 2)}</CodeBlock>
                  </AccordionContent>
                </AccordionItem>
              </Accordion>
            ) : null}
          </section>
        </>
      )}

      <section className="grid gap-4">
        <div className="flex items-baseline justify-between gap-4">
          <h3 className="text-base font-semibold">{t('console.conversations.messages')}</h3>
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

        <CursorPagination
          page={cursorPageNumber(searchParams)}
          hasPrevious={hasPreviousCursor(searchParams)}
          nextCursor={nextCursor}
          resultCount={thread.length}
          onPrevious={() => setSearchParams(previousCursorParams(searchParams))}
          onNext={cursor => setSearchParams(nextCursorParams(searchParams, cursor))}
        />
      </section>
    </PageStack>
  )
}

function BackLink({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <div>
      <button
        type="button"
        onClick={onClick}
        className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
        <RiArrowLeftLine className="size-4" aria-hidden />
        {label}
      </button>
    </div>
  )
}

function DetailField({ label, value, mono = false }: { label: string; value: ReactNode; mono?: boolean }) {
  return (
    <div className="grid content-start gap-1 bg-card p-4">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className={cn('break-all text-sm', mono && 'font-mono text-xs leading-5')}>{value}</dd>
    </div>
  )
}

/**
 * Message stream, Codex-style: user input is a right-aligned bubble, assistant
 * replies flow full-width as Markdown, tool traffic (function_call,
 * function_call_output, reasoning) collapses into one-line tiles that expand
 * to pretty-printed payloads, and checkpoints render as hairline separators.
 * The raw JSON is always reachable via the <RawJSON> fallback so no
 * information is lost for unfamiliar ResponseItem variants.
 */
function MessageThread({ messages }: { messages: AIGatewayMessageItem[] }) {
  return (
    <div className="grid gap-5">
      {messages.map(message => (
        <MessageRow key={message.id} message={message} />
      ))}
    </div>
  )
}

function MessageRow({ message }: { message: AIGatewayMessageItem }) {
  // Checkpoint rows reference a compaction artifact; render as a hairline
  // separator plus the raw artifact reference so it stays inspectable.
  if (message.type === 'checkpoint') {
    return (
      <div className="grid gap-2">
        <div className="flex items-center gap-3 text-xs text-muted-foreground">
          <Badge variant="secondary">checkpoint</Badge>
          <span className="min-w-0 break-all font-mono">{message.id}</span>
          <span className="ml-auto shrink-0">{formatConsoleDate(message.inserted_at)}</span>
        </div>
        <RawJSON value={message.content} />
        <div className="h-px bg-border" aria-hidden />
      </div>
    )
  }

  const text = extractOutputText(message.content)

  // Tool traffic collapses to a one-line summary by default; expanding the
  // tile reveals the individual items and their pretty-printed payloads.
  if (message.role === 'tool' || hasToolItems(message.content)) {
    return (
      <article className="border border-border">
        {text ? (
          <div className="border-b border-border px-4 py-3">
            <MarkdownBody text={text} />
          </div>
        ) : null}
        <Accordion>
          <AccordionItem value="items">
            <AccordionTrigger className="items-center gap-3 px-4 py-2.5 text-xs font-normal hover:no-underline">
              <span className="flex min-w-0 flex-1 items-center gap-2">
                <RiFunctionLine className="size-3.5 shrink-0 text-muted-foreground" aria-hidden />
                <ToolSummary content={message.content} role={message.role} />
                <span className="ml-auto flex shrink-0 items-center gap-2 text-muted-foreground">
                  <MessageStatus message={message} />
                  <span>{formatConsoleDate(message.inserted_at)}</span>
                </span>
              </span>
            </AccordionTrigger>
            <AccordionContent className="border-t border-border pb-0">
              <ToolItems content={message.content} fallbackText={text} />
            </AccordionContent>
          </AccordionItem>
        </Accordion>
      </article>
    )
  }

  // Conversational text, Codex-style: user input is a right-aligned bubble on
  // the layer-01 surface; assistant replies flow full-width without a tile.
  if (message.role === 'user') {
    return (
      <article className="flex justify-end">
        <div className="grid max-w-[85%] gap-1.5 sm:max-w-2xl">
          <header className="flex items-center justify-end gap-2 px-1 text-xs text-muted-foreground">
            <MessageStatus message={message} />
            <span>{formatConsoleDate(message.inserted_at)}</span>
          </header>
          <div className="border border-border bg-card px-4 py-3">
            {text ? <MarkdownBody text={text} /> : <RawJSON value={message.content} />}
          </div>
        </div>
      </article>
    )
  }

  return (
    <article className="grid gap-1.5">
      <header className="flex items-center gap-2 px-1 text-xs text-muted-foreground">
        {message.role && message.role !== 'assistant' ? <Badge variant="secondary">{message.role}</Badge> : null}
        <MessageStatus message={message} />
        <span>{formatConsoleDate(message.inserted_at)}</span>
      </header>
      {text ? <MarkdownBody text={text} /> : <RawJSON value={message.content} />}
    </article>
  )
}

/** One-line summary of a collapsed tool tile: first item's name/type plus a count. */
function ToolSummary({ content, role }: { content: ResponseItem[]; role?: AIGatewayMessageItem['role'] }) {
  const toolItems = content.filter(isToolItem)
  const first = toolItems[0]

  if (!first) {
    return <Badge variant="secondary">{role ?? 'tool'}</Badge>
  }

  return (
    <>
      <Badge variant="outline">{String(first.type ?? 'item')}</Badge>
      {typeof first.name === 'string' ? (
        <span className="truncate font-mono font-medium">{first.name}</span>
      ) : typeof first.call_id === 'string' ? (
        <span className="truncate font-mono text-muted-foreground">{first.call_id}</span>
      ) : null}
      {toolItems.length > 1 ? <span className="shrink-0 text-muted-foreground">+{toolItems.length - 1}</span> : null}
    </>
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
    return (
      <div className="px-4 py-3">
        <RawJSON value={fallbackText || content} />
      </div>
    )
  }

  return (
    <div className="grid divide-y divide-border">
      {toolItems.map((item, index) => (
        <ToolItemView key={index} item={item} />
      ))}
    </div>
  )
}

function ToolItemView({ item }: { item: ResponseItem }) {
  const type = String(item.type ?? 'item')
  const raw = toolItemText(item)

  if (type === 'reasoning') {
    return (
      <div className="grid gap-2 px-4 py-3">
        <ToolItemHeader item={item} type={type} />
        {raw ? <p className="text-xs leading-5 whitespace-pre-wrap text-muted-foreground">{raw}</p> : null}
      </div>
    )
  }

  // The runtime stopped writing the untrusted-content envelope in 0.59.0, but
  // conversation rows stored before that change still carry it. Unwrap those
  // rows and keep the nonce as provenance instead of dumping the wrapper
  // markup into the reading column. Remove this unwrap when no stored
  // conversation carries the envelope.
  const envelope = type === 'function_call_output' ? stripUntrustedEnvelope(raw) : null
  const body = envelope ? envelope.body : raw

  return (
    <div className="grid gap-2 px-4 py-3">
      <ToolItemHeader item={item} type={type} nonce={envelope?.nonce} />
      {body ? <CodeBlock>{prettyJSON(truncate(body, 16_000))}</CodeBlock> : null}
    </div>
  )
}

function ToolItemHeader({ item, type, nonce }: { item: ResponseItem; type: string; nonce?: string }) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
      <Badge variant="outline">{type}</Badge>
      {typeof item.name === 'string' ? <span className="font-mono font-medium">{item.name}</span> : null}
      {typeof item.call_id === 'string' ? (
        <span className="break-all font-mono text-muted-foreground">{item.call_id}</span>
      ) : null}
      {nonce ? <span className="font-mono text-muted-foreground">nonce {nonce}</span> : null}
    </div>
  )
}

/** Monospace payload surface: Carbon layer-01 with a hairline border, no wrapping. */
function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="max-h-80 overflow-auto border border-border bg-card px-3 py-2 font-mono text-xs leading-5 whitespace-pre">
      {children}
    </pre>
  )
}

function RawJSON({ value }: { value: unknown }) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2)
  return <CodeBlock>{truncate(text, 8_000)}</CodeBlock>
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}

/** Re-indents JSON payloads; passes non-JSON text through unchanged. */
function prettyJSON(text: string): string {
  const trimmed = text.trim()
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text
  try {
    return JSON.stringify(JSON.parse(trimmed), null, 2)
  } catch {
    return text
  }
}

const UNTRUSTED_ENVELOPE =
  /^<ankole_untrusted_tool_output nonce="([^"]+)">\s*([\s\S]*?)<\/ankole_untrusted_tool_output[^>]*>\s*$/

function stripUntrustedEnvelope(text: string): { nonce: string; body: string } | null {
  const found = UNTRUSTED_ENVELOPE.exec(text.trim())
  return found ? { nonce: found[1], body: found[2].trim() } : null
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
  if (typeof item.text === 'string') return item.text
  if (Array.isArray(item.summary)) {
    const parts = item.summary
      .map(part => (part && typeof part === 'object' ? (part as Record<string, unknown>).text : undefined))
      .filter((text): text is string => typeof text === 'string')
    if (parts.length > 0) return parts.join('\n')
  }
  if (item.content !== undefined) {
    return typeof item.content === 'string' ? item.content : JSON.stringify(item.content, null, 2)
  }
  return JSON.stringify(item, null, 2)
}
