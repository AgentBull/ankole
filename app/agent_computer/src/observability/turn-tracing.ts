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
import { toError } from '../common/errors'

const tracerName = 'ankole-worker'
const traceparentPattern = /^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/
const observabilityUserIDPrefixes = ['principal:', 'channel:'] as const
const observabilityUserIDMaxCodepoints = 200
const turnIdentityAttributeNames = new Set(['ankole.principal.uid', 'ankole.principal.type', 'user.id', 'session.id'])

export type TurnTracePropagation = {
  traceparent: string
  observabilityUserID: string | null
}

export type WorkerTurnTrace = TurnTracePropagation & {
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
  const propagation = turnTracePropagationFromTurnStart(turnStart)
  if (!propagation || !exportOTLP) return undefined

  const match = propagation.traceparent.match(traceparentPattern)
  if (!match) return undefined
  const [, , traceId, spanId, flags] = match

  ensureProvider()

  return {
    ...propagation,
    parentContext: trace.setSpanContext(ROOT_CONTEXT, {
      traceId: traceId!,
      spanId: spanId!,
      isRemote: true,
      traceFlags: Number.parseInt(flags!, 16) & TraceFlags.SAMPLED
    }),
    attributes: {
      'ankole.principal.uid': turnStart.turn.actor.agent_uid,
      'ankole.principal.type': 'agent',
      ...(propagation.observabilityUserID ? { 'user.id': propagation.observabilityUserID } : {}),
      'session.id': turnStart.turn.actor.session_id
    }
  }
}

/**
 * Reads the canonical trace propagation facts from a persisted TurnStart.
 *
 * Returns `undefined` when the traceparent is invalid. A missing or invalid user
 * identity becomes `null`, so a valid trace can still propagate.
 */
export function turnTracePropagationFromTurnStart(turnStart: TurnStart): TurnTracePropagation | undefined {
  const traceparent = traceparentFromTurnStart(turnStart)
  if (!traceparent) return undefined

  return {
    traceparent,
    observabilityUserID: observabilityUserIDFromTurnStart(turnStart)
  }
}

export function traceparentFromTurnStart(turnStart: TurnStart): string | undefined {
  const value = turnStart.request_context?.traceparent
  if (typeof value !== 'string') return undefined

  const match = value.match(traceparentPattern)
  if (!match) return undefined
  const [, version, traceID, spanID] = match
  if (version === 'ff' || /^0+$/.test(traceID!) || /^0+$/.test(spanID!)) return undefined
  return value
}

function observabilityUserIDFromTurnStart(turnStart: TurnStart): string | null {
  const value = turnStart.request_context?.observability_user_id
  if (typeof value !== 'string' || value !== value.trim() || /[\r\n]/.test(value)) return null
  if ([...value].length > observabilityUserIDMaxCodepoints) return null

  return observabilityUserIDPrefixes.some(prefix => value.startsWith(prefix) && value.length > prefix.length)
    ? value
    : null
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
      attributes: { ...attributes, ...turnTrace.attributes },
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
  if (options.attributes) {
    span.setAttributes(
      Object.fromEntries(Object.entries(options.attributes).filter(([name]) => !turnIdentityAttributeNames.has(name)))
    )
  }

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
      const agentUID = span.attributes['ankole.principal.uid']
      if (typeof agentUID !== 'string' || agentUID.length === 0) {
        callback({ code: 1, error: new Error('worker span has no ankole.principal.uid') })
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
      error => callback({ code: 1, error: toError(error) })
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
