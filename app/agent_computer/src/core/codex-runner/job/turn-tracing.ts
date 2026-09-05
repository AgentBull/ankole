import type { Span } from '@opentelemetry/api'
import {
  finishWorkerSpan,
  startWorkerSpan,
  workerObservationInputAttributes,
  workerObservationOutputAttributes,
  type WorkerTurnTrace
} from '../../../observability/turn-tracing'
import type { CodexToolItem } from './tool-item'

export class CodexTurnTrace {
  private readonly toolSpans = new Map<string, Span>()

  private constructor(
    private readonly trace: WorkerTurnTrace,
    private span: Span | undefined
  ) {}

  static start(
    trace: WorkerTurnTrace | undefined,
    threadID: string,
    turnID: string,
    startTime?: Date,
    input?: string
  ): CodexTurnTrace | undefined {
    if (!trace) return undefined
    const span = startWorkerSpan(
      trace,
      'invoke_agent codex',
      {
        ...workerObservationInputAttributes('agent', input),
        'gen_ai.agent.name': 'codex',
        'ankole.codex.thread.id': threadID,
        'ankole.codex.turn.id': turnID
      },
      { startTime }
    )
    return span ? new CodexTurnTrace(trace, span) : undefined
  }

  setInput(input: string): void {
    this.span?.setAttributes(workerObservationInputAttributes('agent', input))
  }

  startTool(item: CodexToolItem, startTime?: Date): Span | undefined {
    if (!this.span) return undefined
    const existing = this.toolSpans.get(item.id)
    if (existing) return existing
    const { identity } = item
    const name = identity.namespace ? `${identity.namespace}.${identity.name}` : identity.name
    const span = startWorkerSpan(
      this.trace,
      `execute_tool ${name}`,
      {
        ...workerObservationInputAttributes('tool', item.input),
        'gen_ai.tool.name': identity.name,
        ...(identity.namespace ? { 'gen_ai.tool.namespace': identity.namespace } : {}),
        'gen_ai.tool.call.id': item.id
      },
      { parent: this.span, startTime }
    )
    if (span) this.toolSpans.set(item.id, span)
    return span
  }

  finishTool(item: CodexToolItem): void {
    const { durationMs } = item
    const span =
      this.toolSpans.get(item.id) ??
      this.startTool(item, durationMs === undefined ? undefined : new Date(Date.now() - durationMs))
    if (!span) return
    this.toolSpans.delete(item.id)
    finishWorkerSpan(span, {
      errorType: item.errorType,
      attributes: {
        ...workerObservationOutputAttributes('tool', item.output),
        ...(durationMs === undefined ? {} : { 'ankole.codex.duration_ms': durationMs })
      }
    })
  }

  finish(errorType?: string, endTime?: Date, output?: unknown): void {
    for (const span of this.toolSpans.values()) finishWorkerSpan(span, { errorType: errorType ?? 'codex_turn_ended' })
    this.toolSpans.clear()
    if (!this.span) return
    finishWorkerSpan(this.span, {
      errorType,
      attributes: workerObservationOutputAttributes('agent', output),
      endTime
    })
    this.span = undefined
  }
}
