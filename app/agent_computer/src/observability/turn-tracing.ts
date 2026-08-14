import {
  ROOT_CONTEXT,
  SpanKind,
  SpanStatusCode,
  TraceFlags,
  trace,
  type Attributes,
  type Context,
  type Span,
  type TimeInput
} from '@opentelemetry/api'
import {
  BasicTracerProvider,
  BatchSpanProcessor,
  type ReadableSpan,
  type SpanExporter
} from '@opentelemetry/sdk-trace-base'
import { ProtobufTraceSerializer } from '@opentelemetry/otlp-transformer'
import { resourceFromAttributes } from '@opentelemetry/resources'
import type { TurnStart } from '../lanes/actor_lane'

const tracerName = 'ankole-worker'
const traceparentPattern = /^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/

export type WorkerTurnTrace = {
  traceparent: string
  parentContext: Context
  attributes: Attributes
}

type ExportOTLP = (payload: Uint8Array, agentUID: string) => Promise<void>

let exportOTLP: ExportOTLP | undefined
let provider: BasicTracerProvider | undefined

export function configureWorkerTracing(exporter: ExportOTLP): void {
  exportOTLP = exporter
}

export function workerTurnTrace(turnStart: TurnStart): WorkerTurnTrace | undefined {
  const traceparent = traceparentFromTurnStart(turnStart)
  if (!traceparent || !exportOTLP) return undefined

  const match = traceparent.match(traceparentPattern)
  if (!match) return undefined
  const [, version, traceId, spanId, flags] = match
  if (version === 'ff' || /^0+$/.test(traceId!) || /^0+$/.test(spanId!)) return undefined

  ensureProvider()

  return {
    traceparent,
    parentContext: trace.setSpanContext(ROOT_CONTEXT, {
      traceId: traceId!,
      spanId: spanId!,
      isRemote: true,
      traceFlags: Number.parseInt(flags!, 16) & TraceFlags.SAMPLED
    }),
    attributes: {
      'user.id': turnStart.turn.actor.agent_uid,
      'session.id': turnStart.turn.actor.session_id
    }
  }
}

export function traceparentFromTurnStart(turnStart: TurnStart): string | undefined {
  const value = turnStart.request_context?.traceparent
  return typeof value === 'string' && traceparentPattern.test(value) ? value : undefined
}

export function startWorkerSpan(
  turnTrace: WorkerTurnTrace | undefined,
  name: string,
  attributes: Attributes = {},
  options: { parent?: Span; startTime?: TimeInput; kind?: SpanKind } = {}
): Span | undefined {
  if (!turnTrace || !provider) return undefined
  const parentContext = options.parent
    ? trace.setSpan(turnTrace.parentContext, options.parent)
    : turnTrace.parentContext

  return provider.getTracer(tracerName).startSpan(
    name,
    {
      attributes: { ...turnTrace.attributes, ...attributes },
      kind: options.kind ?? SpanKind.INTERNAL,
      ...(options.startTime === undefined ? {} : { startTime: options.startTime })
    },
    parentContext
  )
}

export function finishWorkerSpan(
  span: Span | undefined,
  options: { errorType?: string; attributes?: Attributes; endTime?: TimeInput } = {}
): void {
  if (!span) return
  if (options.attributes) span.setAttributes(options.attributes)

  if (options.errorType) {
    span.setAttribute('error.type', options.errorType)
    span.setStatus({ code: SpanStatusCode.ERROR, message: options.errorType })
  } else {
    span.setStatus({ code: SpanStatusCode.OK })
  }

  span.end(options.endTime)
}

export async function forceFlushWorkerTracing(): Promise<void> {
  if (!provider) return

  try {
    await provider.forceFlush()
  } catch {
    // Trace export is best effort and cannot change Worker shutdown.
  }
}

function ensureProvider(): void {
  if (provider) return
  const exporter = new RuntimeFabricSpanExporter()

  provider = new BasicTracerProvider({
    resource: workerResource(),
    forceFlushTimeoutMillis: 12_000,
    spanProcessors: [
      new BatchSpanProcessor(exporter, {
        exportTimeoutMillis: 10_000
      })
    ]
  })
}

class RuntimeFabricSpanExporter implements SpanExporter {
  export(spans: ReadableSpan[], callback: Parameters<SpanExporter['export']>[1]): void {
    const exporter = exportOTLP
    if (!exporter) {
      callback({ code: 1, error: new Error('worker tracing exporter is not configured') })
      return
    }

    const groups = new Map<string, ReadableSpan[]>()
    for (const span of spans) {
      const agentUID = span.attributes['user.id']
      if (typeof agentUID !== 'string' || agentUID.length === 0) {
        callback({ code: 1, error: new Error('worker span has no user.id') })
        return
      }
      groups.set(agentUID, [...(groups.get(agentUID) ?? []), span])
    }

    Promise.all(
      [...groups].map(async ([agentUID, agentSpans]) => {
        const payload = ProtobufTraceSerializer.serializeRequest(agentSpans)
        if (!payload) throw new Error('worker spans did not serialize')
        await exporter(payload, agentUID)
      })
    ).then(
      () => callback({ code: 0 }),
      error => callback({ code: 1, error: error instanceof Error ? error : new Error(String(error)) })
    )
  }

  async shutdown(): Promise<void> {}
}

function workerResource() {
  return resourceFromAttributes({
    'service.name': tracerName,
    ...(process.env.ANKOLE_VERSION ? { 'service.version': process.env.ANKOLE_VERSION } : {}),
    ...(process.env.ANKOLE_ENV ? { 'deployment.environment.name': process.env.ANKOLE_ENV } : {})
  })
}
