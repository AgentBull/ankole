import { z } from 'zod'
import { arrayPath, isRecord, objectPath, recordValue, stringArg } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type ActivityDescription, type WorkerAgentTool } from '../../core'
import { readTool } from '../../core/read-tools'
import type { JobTurnRef } from '../../lanes/session_lane'
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
  const fallback = opts.renderedFallback
  const renderedFetch = fallback
    ? (urls: string[], signal?: AbortSignal) => renderedFallbackFetch(urls, fallback, signal)
    : undefined
  return [
    defineWorkerTool({
      name: 'web_search',
      description: 'Search the public web through the configured AIGateway web search provider.',
      schema: WebSearchParams,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false,
      describeActivity: params => ({
        key: 'conversations.delivery.reply.activity.web_search',
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
        readTool(opts.rpc, opts.turn, 'web_fetch', params, { cache, signal, renderedFetch })
    })
  ]
}

export async function renderedFallbackFetch(
  urls: string[],
  config: RenderedWebFetchOptions,
  signal?: AbortSignal
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
        error: errorMessage(error),
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
      const fetched = arrayPath(body, ['results'])
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
    results: normalizedResults
  }
}

function renderedFetchError(url: string, error: unknown): JSONObject {
  return {
    url,
    error: errorMessage(error),
    metadata: { source: RenderedFallbackSource }
  }
}

/**
 * Normalizes rendered extract output into the same rough result shape as
 * provider web_fetch.
 */
function normalizeRenderedFetchResult(url: string, value: unknown): JSONObject {
  const record = recordValue(value) ?? { text: String(value ?? '') }
  const metadata = objectPath(record, ['metadata'])
  const result: JSONObject = {
    url: stringArg(record, 'url') || url,
    title: stringArg(record, 'title'),
    text: stringArg(record, 'text') || '',
    metadata: {
      ...metadata,
      source: RenderedFallbackSource
    }
  }

  const error = stringArg(record, 'error')
  if (error) result.error = error
  return result
}

function webFetchActivity(urls: string[]): ActivityDescription {
  const domain = fetchedPageHost(urls[0])
  const target = domain || undefined
  return {
    key:
      urls.length === 1
        ? target
          ? 'conversations.delivery.reply.activity.web_fetch_target'
          : 'conversations.delivery.reply.activity.web_fetch'
        : target
          ? 'conversations.delivery.reply.activity.web_fetch_many_target'
          : 'conversations.delivery.reply.activity.web_fetch_many',
    ...(target ? { bindings: { target, count: urls.length } } : { bindings: { count: urls.length } })
  }
}

/** Adds a returned page title without exposing fetched body text or URL parameters. */
function completedWebFetchActivity(urls: string[], details: WebToolDetails): ActivityDescription {
  const results = arrayPath(details, ['results'])
  const firstTitled = results.find(result => isRecord(result) && stringArg(result, 'title'))
  const record = recordValue(firstTitled ?? results.find(isRecord))
  const title = stringArg(record, 'title')
  const domain = fetchedPageHost(stringArg(record, 'url')) || fetchedPageHost(urls[0])
  const titlePart = title ? `《${activityExcerpt(title, 40)}》` : undefined
  const target = [titlePart, domain].filter(Boolean).join(' · ') || undefined

  return {
    key:
      urls.length === 1
        ? target
          ? 'conversations.delivery.reply.activity.web_fetch_target'
          : 'conversations.delivery.reply.activity.web_fetch'
        : target
          ? 'conversations.delivery.reply.activity.web_fetch_many_target'
          : 'conversations.delivery.reply.activity.web_fetch_many',
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

function isHTTPSURL(value: string): boolean {
  try {
    return new URL(value).protocol === 'https:'
  } catch {
    return false
  }
}

function fetchedPageHost(url: string | undefined): string | undefined {
  try {
    return url ? new URL(url).hostname : undefined
  } catch {
    return undefined
  }
}
