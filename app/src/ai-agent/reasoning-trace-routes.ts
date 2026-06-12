import { Elysia } from 'elysia'
import { z } from 'zod'
import { appConfigService } from '@/config/app-configure'
import { AppI18nDefaultLocaleConfig } from '@/config/i18n'
import { DEFAULT_LOCALE } from '@/config/i18n-locales'
import { externalGatewayRuntime } from '@/external-gateway/runtime'
import { type DevSpaHtmlRenderer, renderSpaHtml } from '@/core/spa-html'
import {
  aiAgentReasoningTraceStream,
  readReasoningTraceToken,
  type ReasoningTraceTokenPayload
} from './reasoning-trace'

interface ReasoningTraceRoutesOptions {
  devSpaHtmlRenderer?: DevSpaHtmlRenderer
}

type ReasoningTraceRouteSet = {
  headers: Record<string, string | number>
  status?: number | string
}

const eventQuery = z.object({
  after: z.string().optional()
})

export function reasoningTraceRoutes(options: ReasoningTraceRoutesOptions = {}) {
  return new Elysia({ name: 'reasoning-trace-routes' })
    .get('/traces/reasoning/:token', context => reasoningTraceHtml(context, options))
    .get(
      '/api/public/reasoning-traces/:token/events',
      async ({ params, query, request, set }) => {
        const payload = await authorizePublicTrace(params.token, request, set)
        if (!payload) return { error: 'reasoning trace is not available' }
        if (!(await traceExists(payload))) {
          set.status = 410
          return { error: 'reasoning trace has expired' }
        }

        const start = typeof query.after === 'string' && query.after.length > 0 ? `(${query.after}` : '-'
        const records = await aiAgentReasoningTraceStream.read({
          agentUid: payload.agentUid,
          conversationId: payload.conversationId,
          traceId: payload.traceId,
          start
        })
        return {
          cursor: records.at(-1)?.redisId ?? query.after ?? null,
          events: records.map(record => ({
            ...record.event,
            at: record.event.at?.toISOString(),
            cursor: record.redisId
          }))
        }
      },
      { query: eventQuery }
    )
}

async function reasoningTraceHtml(
  { params, request, set }: { params: { token: string }; request: Request; set: ReasoningTraceRouteSet },
  options: ReasoningTraceRoutesOptions
) {
  const payload = await authorizePublicTrace(params.token, request, set)
  if (!payload) return { error: 'reasoning trace is not available' }
  if (!(await traceExists(payload))) {
    set.status = 410
    return { error: 'reasoning trace has expired' }
  }

  const response = await renderSpaHtml({
    app: 'reasoning-trace',
    title: 'BullX Reasoning Trace',
    locale: await appLocale(),
    request,
    devRenderer: options.devSpaHtmlRenderer
  })
  const headers = new Headers(response.headers)
  noStore(headers)
  return new Response(response.body, {
    headers,
    status: response.status,
    statusText: response.statusText
  })
}

function traceExists(payload: ReasoningTraceTokenPayload): Promise<boolean> {
  return aiAgentReasoningTraceStream.exists({
    agentUid: payload.agentUid,
    conversationId: payload.conversationId,
    traceId: payload.traceId
  })
}

async function authorizePublicTrace(
  token: string,
  request: Request,
  set: ReasoningTraceRouteSet
): Promise<ReasoningTraceTokenPayload | undefined> {
  noStore(set.headers)
  const payload = readReasoningTraceToken(token)
  if (!payload) {
    set.status = 404
    return undefined
  }

  const authorized = await externalGatewayRuntime.authorizeReasoningTraceView({
    agentUid: payload.agentUid,
    bindingName: payload.bindingName,
    providerRoomId: payload.providerRoomId,
    providerThreadId: payload.providerThreadId,
    request,
    traceId: payload.traceId
  })
  if (!authorized) {
    set.status = 403
    return undefined
  }

  return payload
}

function noStore(headers: Headers | Record<string, string | number>): void {
  if (headers instanceof Headers) {
    headers.set('cache-control', 'no-store')
    headers.set('referrer-policy', 'no-referrer')
    headers.set('x-robots-tag', 'noindex')
    return
  }
  headers['cache-control'] = 'no-store'
  headers['referrer-policy'] = 'no-referrer'
  headers['x-robots-tag'] = 'noindex'
}

async function appLocale(): Promise<string> {
  return (await appConfigService.get(AppI18nDefaultLocaleConfig)) ?? DEFAULT_LOCALE
}
