import { useEffect, useRef, useState } from 'react'
import { BrainIcon, CheckCircleIcon, CircleIcon, WrenchIcon, XCircleIcon } from 'lucide-react'
import {
  ChainOfThought,
  ChainOfThoughtContent,
  ChainOfThoughtHeader,
  ChainOfThoughtStep
} from '@/components/ai-elements/chain-of-thought'
import { Reasoning, ReasoningContent, ReasoningTrigger } from '@/components/ai-elements/reasoning'
import { Task, TaskContent, TaskItem, TaskTrigger } from '@/components/ai-elements/task'
import { Tool, ToolContent, ToolHeader } from '@/components/ai-elements/tool'
import { Badge } from '@/uikit/components/badge'
import { Spinner } from '@/uikit/components/spinner'

export interface ReasoningTraceOutputEvent {
  cursor: string
  type: string
  sequence: number
  at?: string
  delta?: string
  metadata?: Record<string, unknown>
  status?: string
  text?: string
  toolCallId?: string
  toolName?: string
}

export interface ReasoningTraceFetchResult {
  cursor: string | null
  events: ReasoningTraceOutputEvent[]
}

export type ReasoningTraceFetcher = (after?: string) => Promise<ReasoningTraceFetchResult>

type TraceStatus = 'streaming' | 'finished' | 'failed' | 'expired'

interface ToolState {
  id: string
  name: string
  status: string
}

interface ReasoningTraceSnapshot {
  error?: string
  eventCount: number
  lastEventAt?: string
  reasoningText: string
  startedAt?: string
  status: TraceStatus
  tools: ToolState[]
}

/**
 * Polls the Redis-backed reasoning trace stream through the server API.
 *
 * The hook keeps only the last cursor locally; the server owns retention and
 * authorization. When the API reports an expired trace, the UI switches to a
 * terminal state instead of continuing to poll.
 */
export function useReasoningTraceOutput(
  fetchEvents: ReasoningTraceFetcher | undefined,
  resetKey: string
): ReasoningTraceSnapshot {
  const [snapshot, setSnapshot] = useState<ReasoningTraceSnapshot>({
    eventCount: 0,
    reasoningText: '',
    status: 'streaming',
    tools: []
  })
  const cursorRef = useRef<string | undefined>(undefined)

  useEffect(() => {
    if (!fetchEvents) {
      setSnapshot({ eventCount: 0, reasoningText: '', status: 'expired', tools: [] })
      return
    }

    cursorRef.current = undefined
    setSnapshot({ eventCount: 0, reasoningText: '', status: 'streaming', tools: [] })
    let stopped = false

    const tick = async () => {
      try {
        const result = await fetchEvents(cursorRef.current)
        if (stopped) return
        if (result.cursor) cursorRef.current = result.cursor
        setSnapshot(previous => applyReasoningTraceEvents(previous, result.events))
        if (result.events.some(event => event.type === 'trace.finished' || event.type === 'trace.failed')) {
          stopped = true
          clearInterval(timer)
        }
      } catch (error) {
        if (stopped) return
        const message = error instanceof Error ? error.message : String(error)
        setSnapshot(previous => ({
          ...previous,
          error: message,
          status: message.includes('expired') ? 'expired' : previous.status
        }))
      }
    }

    const timer = setInterval(() => void tick(), 1000)
    void tick()
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }, [fetchEvents, resetKey])

  return snapshot
}

/**
 * Renders a compact trace projection without exposing raw tool inputs/outputs.
 */
export function ReasoningTracePanel({ snapshot }: { snapshot: ReasoningTraceSnapshot }) {
  const terminal = snapshot.status !== 'streaming'
  const isStreaming = snapshot.status === 'streaming'
  const activeTools = snapshot.tools.filter(tool => tool.status === 'running').length
  const failedTools = snapshot.tools.filter(tool => tool.status === 'failed').length
  return (
    <div className="flex flex-col gap-4 border-t border-border pt-4">
      <div className="flex items-center justify-between gap-3">
        <div className="text-sm font-medium">Reasoning trace</div>
        {isStreaming ? (
          <Badge variant="secondary">
            <Spinner className="size-3" /> streaming
          </Badge>
        ) : (
          <Badge variant={snapshot.status === 'failed' || snapshot.status === 'expired' ? 'destructive' : 'outline'}>
            {snapshot.status}
          </Badge>
        )}
      </div>
      {snapshot.error ? (
        <div className="rounded-md border border-red-30 bg-red-10 px-3 py-2 text-sm text-red-80">{snapshot.error}</div>
      ) : null}
      <Task defaultOpen={true} className="rounded-md border border-border p-3">
        <TaskTrigger title="Trace summary" />
        <TaskContent>
          <TaskItem>{statusSummary(snapshot.status)}</TaskItem>
          <TaskItem>{snapshot.eventCount} events received</TaskItem>
          <TaskItem>
            {snapshot.reasoningText
              ? 'Reasoning content provided'
              : terminal
                ? 'Reasoning content not provided'
                : 'Waiting for reasoning content'}
          </TaskItem>
          <TaskItem>
            {snapshot.tools.length} tool calls
            {activeTools > 0 ? `, ${activeTools} running` : ''}
            {failedTools > 0 ? `, ${failedTools} failed` : ''}
          </TaskItem>
        </TaskContent>
      </Task>
      <Reasoning
        className="rounded-md border border-border p-3"
        defaultOpen={isStreaming || Boolean(snapshot.reasoningText)}
        isStreaming={isStreaming}>
        <ReasoningTrigger
          getThinkingMessage={(streaming, duration) => {
            if (streaming) return <span>推理中</span>
            if (!snapshot.reasoningText) return <span>模型未提供推理内容</span>
            return <span>{duration === undefined ? '推理内容' : `推理 ${duration}s`}</span>
          }}
        />
        <ReasoningContent className="max-h-80 overflow-y-auto">
          {snapshot.reasoningText || (terminal ? '模型未提供推理内容。' : '等待模型提供推理内容。')}
        </ReasoningContent>
      </Reasoning>
      <ChainOfThought defaultOpen={true} className="rounded-md border border-border p-3">
        <ChainOfThoughtHeader>Trace timeline</ChainOfThoughtHeader>
        <ChainOfThoughtContent>
          <ChainOfThoughtStep
            icon={CheckCircleIcon}
            label="Trace started"
            description={snapshot.startedAt ? formatTraceTime(snapshot.startedAt) : undefined}
            status={snapshot.startedAt ? 'complete' : 'pending'}
          />
          <ChainOfThoughtStep
            icon={BrainIcon}
            label="Reasoning stream"
            description={
              snapshot.reasoningText
                ? `${snapshot.reasoningText.length} characters`
                : terminal
                  ? 'not provided by provider'
                  : 'waiting'
            }
            status={snapshot.reasoningText ? (isStreaming ? 'active' : 'complete') : terminal ? 'complete' : 'pending'}
          />
          <ChainOfThoughtStep
            icon={WrenchIcon}
            label="Tool activity"
            description={snapshot.tools.length ? `${snapshot.tools.length} tool calls` : 'none'}
            status={activeTools > 0 ? 'active' : snapshot.tools.length > 0 || terminal ? 'complete' : 'pending'}
          />
          <ChainOfThoughtStep
            icon={
              snapshot.status === 'failed' || snapshot.status === 'expired'
                ? XCircleIcon
                : terminal
                  ? CheckCircleIcon
                  : CircleIcon
            }
            label="Trace finalized"
            description={snapshot.lastEventAt ? formatTraceTime(snapshot.lastEventAt) : undefined}
            status={terminal ? 'complete' : 'pending'}
          />
        </ChainOfThoughtContent>
      </ChainOfThought>
      <div className="flex flex-col gap-2">
        <div className="text-sm font-medium">Tools</div>
        {snapshot.tools.length > 0 ? (
          <div className="flex flex-col gap-2">
            {snapshot.tools.map(tool => (
              <Tool key={tool.id} defaultOpen={false}>
                <ToolHeader state={toolStateFor(tool.status)} title={tool.name} type={`tool-${tool.name}` as never} />
                <ToolContent>
                  <div className="text-sm text-muted-foreground">Tool input and output are hidden from this trace.</div>
                </ToolContent>
              </Tool>
            ))}
          </div>
        ) : (
          <div className="rounded-md border border-dashed border-border px-3 py-2 text-sm text-muted-foreground">
            暂无工具调用。
          </div>
        )}
      </div>
    </div>
  )
}

/**
 * Applies append-only trace events to the UI snapshot.
 *
 * Reasoning can arrive as deltas or as replacement text, while tool events are
 * keyed by tool call id when available. This reducer mirrors the stream contract
 * without persisting raw event payloads in component state.
 */
function applyReasoningTraceEvents(
  previous: ReasoningTraceSnapshot,
  events: ReasoningTraceOutputEvent[]
): ReasoningTraceSnapshot {
  let reasoningText = previous.reasoningText
  let status = previous.status
  let startedAt = previous.startedAt
  let lastEventAt = previous.lastEventAt
  const tools = new Map(previous.tools.map(tool => [tool.id, tool]))

  for (const event of events) {
    if (event.type === 'trace.started') startedAt = event.at ?? startedAt
    lastEventAt = event.at ?? lastEventAt
    if (event.type === 'reasoning.delta' && typeof event.delta === 'string') reasoningText += event.delta
    if (event.type === 'reasoning.replace' && typeof event.text === 'string') reasoningText = event.text
    if (event.type === 'trace.finished') status = 'finished'
    if (event.type === 'trace.failed') status = 'failed'
    if (event.type === 'tool.started' || event.type === 'tool.updated' || event.type === 'tool.ended') {
      const id = event.toolCallId || `${event.toolName ?? 'tool'}:${event.sequence}`
      tools.set(id, {
        id,
        name: event.toolName || id,
        status: event.status || (event.type === 'tool.started' ? 'running' : 'succeeded')
      })
    }
  }

  return {
    eventCount: previous.eventCount + events.length,
    lastEventAt,
    reasoningText,
    startedAt,
    status,
    tools: [...tools.values()],
    error: undefined
  }
}

function statusSummary(status: TraceStatus): string {
  if (status === 'streaming') return 'Trace is streaming'
  if (status === 'finished') return 'Trace finished'
  if (status === 'failed') return 'Trace failed'
  return 'Trace expired'
}

function toolStateFor(status: string): 'input-available' | 'output-available' | 'output-error' {
  if (status === 'failed') return 'output-error'
  if (status === 'succeeded') return 'output-available'
  return 'input-available'
}

function formatTraceTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleTimeString()
}
