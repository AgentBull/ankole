import { z } from 'zod'
import { isRecord } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type ActivityDescription, type WorkerAgentTool } from '../../core'
import { readTool } from '../../core/read-tools'
import type { JobTurnRef } from '../../lanes/actor_lane'
import type { RPCRequester } from '../../lanes/rpc_lane'
import { errorMessage } from '../../common/errors'

type WebToolDetails = JSONObject
const RenderedFallbackSource = 'rendered_fallback'
export interface CreateWebToolsOptions {
  rpc: RPCRequester
  turn: JobTurnRef
  renderedFallback?: RenderedWebFetchOptions
}
export interface RenderedWebFetchOptions {
  ssrfFilter?: boolean
  fetchBatch: RenderedWebFetchBatch
}
export type RenderedWebFetchBatch = (urls: string[], signal?: AbortSignal) => Promise<unknown>

const WebSearchParams = z.object({
  query: z.string().min(1).describe('Search query.'),
  limit: z.number().int().min(1).max(100).optional().describe('Maximum result count. Defaults to 5.')
})

const HTTPSURL = z
  .string()
  .url()
  .refine(value => isHTTPSURL(value), 'Only HTTPS URLs are supported.')

const WebFetchParams = z.object({
  result_offset: z.number().int().min(0).optional().describe('UTF-8 byte offset from next_offset. Defaults to 0.'),
  urls: z
    .array(HTTPSURL)
    .min(1)
    .max(5)
    .describe('HTTPS web-page URLs whose readable text should be extracted. Do not pass binary-file URLs. Maximum 5.')
})

/** Job transport and browser fallback for the shared control-plane web tools. */
export async function createWebTools(opts: CreateWebToolsOptions): Promise<WorkerAgentTool[]> {
  const cache: JSONObject = {}
  return [
    defineWorkerTool({
      name: 'web_search',
      description: 'Search the public web through the configured AIGateway web search provider.',
      schema: WebSearchParams,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false,
      describeActivity: params => ({
        key: 'signals_gateway.reply.activity.web_search',
        bindings: { query: activityExcerpt(params.query, 48) }
      }),
      execute: (_id, params, signal) => readTool(opts.rpc, opts.turn, 'web_search', params, { signal })
    }),
    defineWorkerTool({
      name: 'web_fetch',
      description:
        'Extract readable text from HTTPS web pages. Binary files require the command shell. A longer page returns next_offset; use the same URL and result_offset to read its next window.',
      schema: WebFetchParams,
      executionMode: 'sequential',
      isReadOnly: true,
      isDestructive: false,
      describeActivity: params => webFetchActivity(params.urls),
      describeCompletedActivity: (params, result) => completedWebFetchActivity(params.urls, result.details),
      execute: (_id, params, signal) =>
        readTool(opts.rpc, opts.turn, 'web_fetch', params, { cache, signal, renderedFallback: opts.renderedFallback })
    })
  ]
}

export async function renderedFallbackFetch(
  urls: string[],
  config: RenderedWebFetchOptions,
  signal?: AbortSignal,
  fallbackReason?: string
): Promise<JSONObject> {
  const results: Array<JSONObject | undefined> = Array.from({ length: urls.length })
  const accepted: Array<{ url: string; index: number }> = []

  for (const [index, url] of urls.entries()) {
    if (signal?.aborted) throw new Error('web_fetch aborted')
    try {
      if (!isHTTPSURL(url)) throw new Error('Only HTTPS URLs are supported.')
      accepted.push({ url, index })
    } catch (error) {
      if (signal?.aborted) throw error
      results[index] = {
        url,
        error: renderedFallbackErrorMessage(error),
        metadata: {
          source: RenderedFallbackSource
        }
      }
    }
  }

  if (accepted.length > 0) {
    try {
      const body = await config.fetchBatch(
        accepted.map(item => item.url),
        signal
      )
      const fetched = Array.isArray(isRecord(body) ? body.results : undefined)
        ? (body as { results: unknown[] }).results
        : []
      for (const [offset, item] of accepted.entries()) {
        results[item.index] = normalizeRenderedFetchResult(item.url, fetched[offset])
      }
    } catch (error) {
      if (signal?.aborted) throw error
      for (const item of accepted) results[item.index] = renderedFetchError(item.url, error)
    }
  }

  const normalizedResults = results.map((result, index) => result ?? renderedFetchError(urls[index]!, 'no result'))

  return {
    success: normalizedResults.every(result => typeof result.error !== 'string'),
    source: RenderedFallbackSource,
    ...(fallbackReason ? { fallback_from: 'aigateway', fallback_reason: fallbackReason } : {}),
    results: normalizedResults
  }
}

function renderedFetchError(url: string, error: unknown): JSONObject {
  return {
    url,
    error: renderedFallbackErrorMessage(error),
    metadata: { source: RenderedFallbackSource }
  }
}

/**
 * Normalizes rendered extract output into the same rough result shape as
 * provider web_fetch.
 */
function normalizeRenderedFetchResult(url: string, value: unknown): JSONObject {
  const record = isRecord(value) ? value : { text: String(value ?? '') }
  const metadata = isRecord(record.metadata) ? record.metadata : {}
  const result: JSONObject = {
    url: stringField(record, 'url') || url,
    title: stringField(record, 'title'),
    text: stringField(record, 'text') || '',
    metadata: {
      ...metadata,
      source: RenderedFallbackSource
    }
  }

  const error = stringField(record, 'error')
  if (error) result.error = error
  return result
}

/** Builds a parameter-only label before web_fetch returns page metadata. */
function webFetchActivity(urls: string[]): ActivityDescription {
  const domain = fetchedPageHost(urls[0])
  const target = domain || undefined
  return {
    key:
      urls.length === 1
        ? target
          ? 'signals_gateway.reply.activity.web_fetch_target'
          : 'signals_gateway.reply.activity.web_fetch'
        : target
          ? 'signals_gateway.reply.activity.web_fetch_many_target'
          : 'signals_gateway.reply.activity.web_fetch_many',
    ...(target ? { bindings: { target, count: urls.length } } : { bindings: { count: urls.length } })
  }
}

/** Adds a returned page title without exposing fetched body text or URL parameters. */
function completedWebFetchActivity(urls: string[], details: WebToolDetails): ActivityDescription {
  const results = Array.isArray(details.results) ? details.results : []
  const firstTitled = results.find(result => isRecord(result) && stringField(result, 'title'))
  const firstResult = firstTitled ?? results.find(isRecord)
  const record = isRecord(firstResult) ? firstResult : undefined
  const title = record ? stringField(record, 'title') : undefined
  const domain = fetchedPageHost(record ? stringField(record, 'url') : undefined) || fetchedPageHost(urls[0])
  const titlePart = title ? `《${activityExcerpt(title, 40)}》` : undefined
  const target = [titlePart, domain].filter(Boolean).join(' · ') || undefined

  return {
    key:
      urls.length === 1
        ? target
          ? 'signals_gateway.reply.activity.web_fetch_target'
          : 'signals_gateway.reply.activity.web_fetch'
        : target
          ? 'signals_gateway.reply.activity.web_fetch_many_target'
          : 'signals_gateway.reply.activity.web_fetch_many',
    ...(target ? { bindings: { target, count: urls.length } } : { bindings: { count: urls.length } })
  }
}

function activityExcerpt(value: string, maxCharacters: number): string {
  const normalized = value
    // oxlint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  const characters = Array.from(normalized)
  return characters.length <= maxCharacters
    ? normalized
    : `${characters.slice(0, Math.max(0, maxCharacters - 1)).join('')}…`
}

/** Hides renderer implementation details from model-visible fallback errors. */
function renderedFallbackErrorMessage(error: unknown): string {
  const message = errorMessage(error)
  if (/ankole-browser|browser daemon|playwright|chromium|\bCDP\b|browser session/i.test(message)) {
    return 'rendered fallback is temporarily unavailable'
  }
  return message
    .replace(/local browser/gi, 'rendered fallback')
    .replace(/blocked browser navigation/gi, 'blocked rendered fetch')
    .replace(/browser navigation/gi, 'rendered fetch')
    .replace(/browser session/gi, 'rendered-fetch session')
    .replace(/browser returned/gi, 'rendered fallback returned')
    .replace(/browser_[a-z0-9_]+/gi, 'rendered-fetch operation')
}

/**
 * Accepts HTTPS URLs for web_fetch.
 */
function isHTTPSURL(value: string): boolean {
  try {
    return new URL(value).protocol === 'https:'
  } catch {
    return false
  }
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  return typeof record[key] === 'string' ? (record[key] as string) : undefined
}
function fetchedPageHost(url: string | undefined): string | undefined {
  try {
    return url ? new URL(url).hostname : undefined
  } catch {
    return undefined
  }
}
