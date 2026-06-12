import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsoleAgentLiveStream } from '@/console/service'
import { Badge } from '@/uikit/components/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/uikit/components/empty'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { ErrorAlert, SectionHeader } from '../shared'
import {
  ReasoningTracePanel,
  useReasoningTraceOutput,
  type ReasoningTraceFetcher
} from '@/apps/reasoning-trace/trace-view'

type LiveStatus = 'streaming' | 'finished' | 'failed'

/**
 * Incrementally tails one visible-output stream through the console live-output
 * endpoint, accumulating deltas client-side with an exclusive Redis cursor.
 */
function useLiveOutput(agentUid: string | undefined, stream: ConsoleAgentLiveStream | undefined) {
  const [text, setText] = useState('')
  const [status, setStatus] = useState<LiveStatus>('streaming')
  const cursorRef = useRef<string | undefined>(undefined)

  useEffect(() => {
    if (!agentUid || !stream?.streamId) return
    const streamId = stream.streamId
    setText('')
    setStatus('streaming')
    cursorRef.current = undefined
    let stopped = false

    const tick = async () => {
      try {
        const result = await unwrap(
          api.console.agents({ uid: agentUid })['live-output'].get({
            query: {
              conversationId: stream.conversationId,
              streamId,
              after: cursorRef.current
            }
          })
        )
        if (stopped) return
        if (result.cursor) cursorRef.current = result.cursor
        const deltas = result.events.flatMap(event => (typeof event.delta === 'string' ? [event.delta] : []))
        if (deltas.length > 0) setText(previous => previous + deltas.join(''))
        const terminal = result.events.findLast(
          event => event.type === 'stream.finished' || event.type === 'stream.failed'
        )
        if (terminal) {
          setStatus(terminal.type === 'stream.finished' ? 'finished' : 'failed')
          stopped = true
          clearInterval(timer)
        }
      } catch {
        // Polling is best-effort; the next tick retries.
      }
    }

    const timer = setInterval(() => void tick(), 1000)
    void tick()
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [agentUid, stream?.conversationId, stream?.streamId])

  return { text, status }
}

function LiveStreamView({ agentUid, stream }: { agentUid: string; stream: ConsoleAgentLiveStream }) {
  const { t } = useTranslation()
  const { text, status } = useLiveOutput(agentUid, stream)
  const traceFetcher = useMemo<ReasoningTraceFetcher | undefined>(() => {
    if (!stream.reasoningTraceId) return undefined
    return after =>
      unwrap(
        api.console.agents({ uid: agentUid })['reasoning-trace-output'].get({
          query: {
            conversationId: stream.conversationId,
            traceId: stream.reasoningTraceId!,
            after
          }
        })
      )
  }, [agentUid, stream.conversationId, stream.reasoningTraceId])
  const trace = useReasoningTraceOutput(traceFetcher, `${stream.conversationId}:${stream.reasoningTraceId ?? ''}`)

  return (
    <Card size="sm">
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle className="text-base font-mono">{stream.conversationId.slice(0, 8)}</CardTitle>
        {stream.streamId && status === 'streaming' ? (
          <Badge variant="secondary">
            <Spinner className="size-3" /> {t('console.live.streaming')}
          </Badge>
        ) : (
          <Badge variant={status === 'finished' || stream.status === 'completed' ? 'outline' : 'destructive'}>
            {stream.status === 'completed' ? t('console.live.finished') : t(`console.live.${status}`)}
          </Badge>
        )}
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {stream.streamId ? (
          <pre className="max-h-96 overflow-y-auto whitespace-pre-wrap break-words text-sm">
            {text || t('console.live.waiting')}
          </pre>
        ) : null}
        {stream.reasoningTraceId ? <ReasoningTracePanel snapshot={trace} /> : null}
      </CardContent>
    </Card>
  )
}

export function LivePage() {
  const { t } = useTranslation()
  const [selectedUid, setSelectedUid] = useState<string>('')
  const agents = useQuery({
    queryKey: ['console-agents'],
    queryFn: () => unwrap(api.console.agents.get())
  })
  const agentUid = selectedUid || agents.data?.agents[0]?.uid || ''
  const streams = useQuery({
    queryKey: ['console-live-streams', agentUid],
    enabled: agentUid.length > 0,
    refetchInterval: 2000,
    queryFn: () => unwrap(api.console.agents({ uid: agentUid })['live-streams'].get())
  })

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.live.title')} description={t('console.live.description')} />
      {agents.error ? <ErrorAlert error={agents.error} title={t('console.live.agents_failed')} /> : null}
      {streams.error ? <ErrorAlert error={streams.error} title={t('console.live.streams_failed')} /> : null}
      <div className="max-w-sm">
        <Select value={agentUid} onValueChange={value => setSelectedUid(value ?? '')}>
          <SelectTrigger>
            <SelectValue placeholder={t('console.live.select_agent')} />
          </SelectTrigger>
          <SelectContent>
            {(agents.data?.agents ?? []).map(agent => (
              <SelectItem key={agent.uid} value={agent.uid}>
                {agent.displayName || agent.uid}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      {(streams.data?.streams ?? []).map(stream => (
        <LiveStreamView
          key={`${stream.conversationId}:${stream.streamId ?? stream.reasoningTraceId ?? 'trace'}`}
          agentUid={agentUid}
          stream={stream}
        />
      ))}
      {agentUid && streams.data && streams.data.streams.length === 0 ? (
        <Empty>
          <EmptyHeader>
            <EmptyTitle>{t('console.live.empty_title')}</EmptyTitle>
            <EmptyDescription>{t('console.live.empty_body')}</EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : null}
    </div>
  )
}
