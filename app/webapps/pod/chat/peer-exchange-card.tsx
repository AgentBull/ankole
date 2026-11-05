import { Button } from '@ankole/uikit'
import { RiArrowRightUpLine, RiCheckLine, RiStopCircleLine } from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { TFunction } from 'i18next'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { agentsQuery, conversationEventsURL, podKeys, type PodActivity } from '../api'
import { podPeerExchange, stopPodPeerExchange } from '../api/generated/sdk.gen'
import { ContentError } from '../content-primitives'
import { MessagePageReference } from '../message-artifacts'
import { ChatMarkdown } from './chat-markdown'
import { CollapsedWorkView, ActivityView } from './collapsed-work-view'
import { formatElapsed } from './elapsed'
import type { ExecutionSummary, InspectorTarget, TimelineMessage } from './types'

type Peer = { exchange_id: string; agent_uid: string }
const active = (status?: string) => ['running', 'queued', 'retrying'].includes(status ?? '')

export function peerExchangeStateLabel(
  t: TFunction,
  options: {
    status?: string
    isPending?: boolean
    hasReply?: boolean
    elapsed?: string
  }
): string {
  const { status, isPending = false, hasReply = false, elapsed } = options
  if (status === 'waiting_choice') return t('pod.superagent.delegation_waiting')
  if (status === 'retrying') return t('pod.chat_timeline.retrying')
  if (status === 'queued') return t('pod.chat_timeline.queued')
  if (active(status)) return t('pod.superagent.delegation_running')
  if (hasReply || status === 'completed' || status === 'succeeded') {
    return elapsed
      ? t('pod.superagent.delegation_done', { time: elapsed })
      : t('pod.superagent.delegation_done_untimed')
  }
  if (isPending) return t('pod.superagent.delegation_sent')
  return t('pod.superagent.delegation_ended')
}

/**
 * Pairs each delegation the assistant sends with the colleague reply that answers it. One exchange can carry
 * several delegations in turn, so a reply belongs to the nearest earlier delegation of the same exchange. A reply
 * whose delegation is outside the loaded history keeps its own row.
 */
export function pairPeerExchanges(messages: Pick<TimelineMessage, 'id' | 'richContent'>[]) {
  const replies = new Map<string, string>()
  const paired = new Set<string>()
  const latest = new Map<string, string>()
  const open = new Map<string, string>()
  for (const message of messages) {
    const outbound = message.richContent?.agent_peer_outbound
    const inbound = message.richContent?.agent_peer_inbound
    if (outbound) {
      open.set(outbound.exchange_id, message.id)
      latest.set(outbound.exchange_id, message.id)
    } else if (inbound) {
      const request = open.get(inbound.exchange_id)
      if (request) {
        replies.set(request, message.id)
        paired.add(message.id)
        open.delete(inbound.exchange_id)
      }
    }
  }
  return { replies, paired, latest: new Set(latest.values()) }
}

/**
 * One delegation from the assistant to a colleague. The row states who has the work and where it stands, and
 * once the colleague answers, it shows the start of the answer, so the user does not have to open anything to
 * learn the result. The details drawer holds the whole exchange.
 */
export function PeerExchangeCard({
  conversationID,
  peer,
  request,
  reply,
  live = true,
  isActive = false,
  onOpenInspector
}: {
  conversationID: string
  peer: Peer
  request?: TimelineMessage
  reply?: TimelineMessage
  /** Only the latest delegation of an exchange follows the colleague's current state. */
  live?: boolean
  isActive?: boolean
  onOpenInspector?: (target: InspectorTarget, trigger?: HTMLElement | null) => void
}) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const trigger = useRef<HTMLButtonElement>(null)
  const agents = useQuery(agentsQuery)
  const colleague = agents.data?.agents.find(agent => agent.uid === peer.agent_uid)
  const name = colleague?.displayName ?? `@${peer.agent_uid}`
  const path = { id: conversationID, exchange_id: peer.exchange_id }
  const key = [...podKeys.detail(conversationID), 'peer', peer.exchange_id]
  const query = useQuery({
    queryKey: key,
    queryFn: ({ signal }) => podPeerExchange({ path, signal }),
    enabled: live,
    refetchInterval: query => (active(query.state.data?.status) ? 2000 : false)
  })
  const stop = useMutation({
    mutationFn: () => stopPodPeerExchange({ path }),
    onSuccess: () => client.invalidateQueries({ queryKey: podKeys.detail(conversationID) })
  })
  const status = live ? query.data?.status : undefined
  const working = active(status)
  const waiting = status === 'waiting_choice'
  const stoppable = working || waiting
  const task = request?.text.replace(/\s+/g, ' ').trim()
  const elapsedMs = request && reply ? Date.parse(reply.createdAt) - Date.parse(request.createdAt) : 0
  const elapsed = elapsedMs >= 1000 ? formatElapsed(elapsedMs, i18n.language) : undefined
  const state = peerExchangeStateLabel(t, {
    status,
    isPending: live && query.isPending,
    hasReply: Boolean(reply),
    elapsed
  })
  const pages = (reply ?? request)?.links.filter(link => link.kind === 'page') ?? []
  return (
    <div
      className="pod-peer-exchange"
      data-peer-exchange={peer.exchange_id}
      data-active={isActive || undefined}
      data-state={waiting ? 'waiting' : working ? 'working' : reply ? 'done' : 'ended'}>
      <div className="pod-peer-exchange-head">
        {working ? (
          <span className="pod-chat-status-dot pod-chat-status-streaming" aria-hidden />
        ) : reply ? (
          <RiCheckLine aria-hidden />
        ) : (
          <RiArrowRightUpLine aria-hidden />
        )}
        <p className="pod-peer-exchange-summary" title={task}>
          {request ? (
            <>
              {t('pod.superagent.delegated_to', { name })}
              {task && <span className="text-fg-tertiary"> · {task}</span>}
            </>
          ) : (
            t('pod.superagent.reply_from', { name })
          )}
        </p>
        <span role="status" className="pod-peer-exchange-state">
          {state}
        </span>
        <Button
          ref={trigger}
          size="xs"
          variant="ghost"
          aria-expanded={isActive || undefined}
          onClick={() =>
            onOpenInspector?.(
              {
                type: 'peer',
                exchangeID: peer.exchange_id,
                agentUID: peer.agent_uid
              },
              trigger.current
            )
          }>
          {t('pod.superagent.details')}
        </Button>
        {stoppable && (
          <Button
            size="xs"
            variant="ghost"
            disabled={stop.isPending}
            aria-label={t('pod.superagent.stop_delegation', { name })}
            onClick={() => stop.mutate()}>
            {t('pod.superagent.stop')}
          </Button>
        )}
      </div>
      {reply?.text && <ReplyExcerpt text={reply.text} />}
      {!!pages.length && (
        <ul className="pod-peer-exchange-pages">
          {pages.map(link => (
            <li key={link.id}>
              <MessagePageReference id={link.id} />
            </li>
          ))}
        </ul>
      )}
      <ContentError error={query.error || stop.error} retry={() => void query.refetch()} />
    </div>
  )
}

/** The start of the colleague's answer; the full answer stays one click away in the details drawer. */
function ReplyExcerpt({ text }: { text: string }) {
  const body = useRef<HTMLDivElement>(null)
  const [clipped, setClipped] = useState(false)
  useEffect(() => {
    const element = body.current
    if (!element) return
    const measure = () => setClipped(element.scrollHeight > element.clientHeight + 1)
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    return () => observer.disconnect()
  }, [text])
  return (
    <div ref={body} className="pod-peer-exchange-reply" data-clipped={clipped || undefined}>
      <ChatMarkdown text={text} generated />
    </div>
  )
}

function PeerLog({
  conversationID,
  peer,
  state,
  stoppable,
  stopping,
  onStop,
  waiting
}: {
  conversationID: string
  peer: Peer
  state: string
  stoppable: boolean
  stopping: boolean
  onStop(): void
  waiting: boolean
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const agents = useQuery(agentsQuery)
  const names = new Map(
    [...(agents.data?.agents ?? []), ...(agents.data?.personalAssistant ? [agents.data.personalAssistant] : [])].map(
      agent => [agent.uid, agent.displayName]
    )
  )
  const [live, setLive] = useState<{ responseID: string; text: string } | null>(null)
  const [activity, setActivity] = useState<PodActivity | null>(null)
  const key = [...podKeys.detail(conversationID), 'peer', peer.exchange_id, 'messages']
  const logs = useInfiniteQuery({
    queryKey: key,
    initialPageParam: 0,
    queryFn: ({ pageParam, signal }) =>
      podPeerExchange({
        path: { id: conversationID, exchange_id: peer.exchange_id },
        query: { cursor: pageParam },
        signal
      }),
    getNextPageParam: page => page.nextCursor ?? undefined
  })
  useEffect(() => {
    const url = new URL(conversationEventsURL(peer.exchange_id), window.location.origin)
    url.searchParams.set('originConversationID', conversationID)
    const events = new EventSource(url)
    const reload = () => {
      void client.invalidateQueries({ queryKey: [...podKeys.detail(conversationID), 'peer', peer.exchange_id] })
    }
    for (const type of ['started', 'snapshot', 'delta']) {
      events.addEventListener(type, event => {
        const frame = JSON.parse((event as MessageEvent<string>).data) as {
          agentUID: string
          responseID: string
          text?: string
        }
        if (frame.agentUID !== peer.agent_uid) return
        setLive(previous => ({
          responseID: frame.responseID,
          text:
            type === 'delta'
              ? (previous?.responseID === frame.responseID ? previous.text : '') + (frame.text ?? '')
              : (frame.text ?? '')
        }))
      })
    }
    events.addEventListener('activity', event => {
      const frame = JSON.parse((event as MessageEvent<string>).data) as PodActivity
      if (frame.agentUID === peer.agent_uid) setActivity(frame)
    })
    events.addEventListener('conversation', () => {
      setLive(null)
      reload()
    })
    events.addEventListener('access_revoked', () => {
      events.close()
      setLive(null)
      setActivity(null)
      reload()
    })
    events.onopen = reload
    return () => events.close()
  }, [client, conversationID, peer.exchange_id, peer.agent_uid])
  const currentActivity = activity ?? logs.data?.pages[0]?.activity
  return (
    <div className="pod-chat-execution-detail pod-peer-log">
      <div className="pod-peer-log-status">
        <span role="status">{state}</span>
        {stoppable && (
          <Button size="xs" variant="outline" disabled={stopping} onClick={onStop}>
            <RiStopCircleLine aria-hidden />
            {t('pod.superagent.stop_delegation', { name: names.get(peer.agent_uid) ?? `@${peer.agent_uid}` })}
          </Button>
        )}
      </div>
      {waiting && <p className="pod-peer-log-note">{t('pod.superagent.answer_in_conversation')}</p>}
      {logs.data?.pages
        .flatMap(page => page.messages)
        .map(message => (
          <article key={message.id} className="pod-peer-log-message">
            <p className="pod-peer-log-author">
              {names.get(message.authorUID ?? '') ??
                (message.authorUID ? `@${message.authorUID}` : t('pod.chat_timeline.agent'))}
            </p>
            <CollapsedWorkView execution={(message.execution ?? {}) as ExecutionSummary} />
            {message.text && <ChatMarkdown text={message.text} generated />}
          </article>
        ))}
      {logs.hasNextPage && (
        <Button size="sm" variant="ghost" disabled={logs.isFetchingNextPage} onClick={() => void logs.fetchNextPage()}>
          {t('pod.chat_timeline.load_more_execution')}
        </Button>
      )}
      {currentActivity?.state === 'active' && <ActivityView activity={currentActivity} />}
      {live?.text && <ChatMarkdown text={live.text} generated streaming />}
      <ContentError error={logs.error} retry={() => void logs.refetch()} />
    </div>
  )
}

export function PeerExchangeInspectorBody({
  conversationID,
  exchangeID,
  agentUID
}: {
  conversationID: string
  exchangeID: string
  agentUID: string
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const path = { id: conversationID, exchange_id: exchangeID }
  const query = useQuery({
    queryKey: [...podKeys.detail(conversationID), 'peer', exchangeID],
    queryFn: ({ signal }) => podPeerExchange({ path, signal }),
    refetchInterval: q => (active(q.state.data?.status) ? 2000 : false)
  })
  const stop = useMutation({
    mutationFn: () => stopPodPeerExchange({ path }),
    onSuccess: () => client.invalidateQueries({ queryKey: podKeys.detail(conversationID) })
  })
  const status = query.data?.status
  const working = active(status)
  const waiting = status === 'waiting_choice'
  const stoppable = working || waiting
  const hasReply = Boolean(
    query.data?.messages?.some(message => message.authorUID === agentUID && Boolean(message.text?.trim()))
  )
  const state = peerExchangeStateLabel(t, {
    status,
    isPending: query.isPending,
    hasReply
  })
  return (
    <PeerLog
      conversationID={conversationID}
      peer={{ exchange_id: exchangeID, agent_uid: agentUID }}
      state={state}
      stoppable={stoppable}
      stopping={stop.isPending}
      onStop={() => stop.mutate()}
      waiting={waiting}
    />
  )
}
