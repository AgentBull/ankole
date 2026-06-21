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

/**
 * Public, token-gated HTTP surface for viewing a reasoning trace: the SPA shell
 * and its polling events endpoint. "Public" means unauthenticated by session —
 * the bearer of the signed token is the principal, and every request re-runs the
 * authorization check (see {@link authorizePublicTrace}); there is no trust
 * carried between the two routes.
 */
export function reasoningTraceRoutes(options: ReasoningTraceRoutesOptions = {}) {
  return new Elysia({ name: 'reasoning-trace-routes' })
    .get('/traces/reasoning/:token', context => reasoningTraceHtml(context, options))
    .get(
      '/api/public/reasoning-traces/:token/events',
      async ({ params, query, request, set }) => {
        // Re-authorize on every poll, not just on the initial page load: access
        // can be revoked mid-stream, and the events feed is where the actual
        // reasoning content leaves the system.
        const payload = await authorizePublicTrace(params.token, request, set)
        if (!payload) return { error: 'reasoning trace is not available' }
        // Authorized but the stream is gone (past its 24h TTL): 410 Gone tells the
        // client to stop polling, distinct from a 403/404 authorization failure.
        if (!(await traceExists(payload))) {
          set.status = 410
          return { error: 'reasoning trace has expired' }
        }

        // `after` is the last seen entry id; `(<id>` makes XRANGE exclusive so a
        // poll returns only newer events. Absent => start from the beginning (`-`).
        const start = typeof query.after === 'string' && query.after.length > 0 ? `(${query.after}` : '-'
        const records = await aiAgentReasoningTraceStream.read({
          agentUid: payload.agentUid,
          conversationId: payload.conversationId,
          traceId: payload.traceId,
          start
        })
        // Next cursor is the last returned id; with no new events, echo back the
        // caller's `after` so it keeps polling from the same place rather than
        // restarting from the head.
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

// Serves the SPA shell for the viewer. Gated by the same authorization as the
// events feed so an unauthorized or expired token never even gets the page; the
// shell then polls the events endpoint for the live content.
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

/**
 * The single authorization gate for both routes. Fail-closed: any failure path
 * returns `undefined` (with the status set) and the caller refuses to serve, so
 * the default is deny. Two independent checks must both pass — first the token is
 * cryptographically opened and validated (forged/expired/malformed => 404), then
 * the gateway re-confirms the bearer may view *this* trace given its binding and
 * provider room/thread (not authorized => 403). The token alone is necessary but
 * not sufficient; live access is re-evaluated against the gateway each call, so a
 * leaked link does not outlive the viewer's actual membership.
 */
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

// Marks every trace response uncacheable and unindexable. Reasoning content is
// sensitive and addressed by a bearer token in the URL, so it must never be
// stored by a shared cache, sent as a referrer, or picked up by a crawler.
// Handles both header carriers (a plain `set.headers` map and a `Headers`).
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
