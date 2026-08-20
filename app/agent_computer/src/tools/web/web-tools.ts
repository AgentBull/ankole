import { z } from 'zod'
import { webURLFacts } from '@ankole/kernel'
import {
  deepString,
  isRecord,
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify
} from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type ActivityDescription, type AgentToolResult, type WorkerAgentTool } from '../../core'
import type { AIGatewayHTTPClient } from '../../core/ai_gateway_transport'
import { errorMessage } from '../../common/errors'
import { WEB_FETCH_BUDGET_CHARS, fetchedPageHost, renderFetchedPages, stringField } from './fetched-page-text'

type WebToolDetails = JSONObject
const RenderedFallbackSource = 'rendered_fallback'
const WebSearchSelector = 'web_search.default'
const WebFetchSelector = 'web_fetch.default'

export interface CreateWebToolsOptions {
  aiGateway: AIGatewayHTTPClient
  /** Session or Job workspace that receives the full text of a truncated page. */
  workspaceRoot: string
  renderedFallback?: RenderedWebFetchOptions
}

export interface RenderedWebFetchOptions {
  ssrfFilter?: boolean
  fetchBatch?: RenderedWebFetchBatch
  fetchURL?: RenderedWebFetchURL
}

export type RenderedWebFetchBatch = (urls: string[], signal?: AbortSignal) => Promise<unknown>
export type RenderedWebFetchURL = (input: { url: string; index: number }, signal?: AbortSignal) => Promise<unknown>

const WebSearchParams = z.object({
  query: z.string().min(1).describe('Search query.'),
  limit: z.number().int().min(1).max(100).optional().describe('Maximum result count. Defaults to 5.')
})

const HTTPSURL = z
  .string()
  .url()
  .refine(value => isHTTPSURL(value), 'Only HTTPS URLs are supported.')

const WebFetchParams = z.object({
  urls: z
    .array(HTTPSURL)
    .min(1)
    .max(5)
    .describe('HTTPS web-page URLs whose readable text should be extracted. Do not pass binary-file URLs. Maximum 5.')
})

/**
 * Creates a stable web-tool catalog that uses AIGateway semantic selectors.
 *
 * AIGateway resolves current provider configuration when the tool runs.
 * web_fetch can fall back to an internal rendered-page extractor, while
 * web_search remains provider-backed because the worker does not own a search index.
 */
export async function createWebTools(opts: CreateWebToolsOptions): Promise<WorkerAgentTool<any>[]> {
  return [
    createWebSearchTool(opts.aiGateway),
    createWebFetchTool(opts.aiGateway, {
      workspaceRoot: opts.workspaceRoot,
      renderedFallback: opts.renderedFallback
    })
  ]
}

/**
 * Builds the provider-backed web_search tool.
 */
function createWebSearchTool(aiGateway: AIGatewayHTTPClient): WorkerAgentTool<typeof WebSearchParams, WebToolDetails> {
  return defineWorkerTool({
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
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      const body = await postAIGatewayJSON(
        aiGateway,
        '/web_search',
        {
          model: WebSearchSelector,
          query: params.query,
          ...(params.limit ? { limit: params.limit } : {})
        },
        signal
      )

      return {
        content: [{ type: 'text', text: formatSearchResults(body) }],
        details: detailsObject(body)
      }
    }
  })
}

/**
 * Builds web_fetch with provider-first and an optional rendered-page fallback.
 *
 * Provider fetch is preferred when configured because it can use gateway-owned
 * extraction services. The internal fallback keeps rendered pages reachable when
 * the provider path is unavailable.
 */
function createWebFetchTool(
  aiGateway: AIGatewayHTTPClient,
  config: {
    workspaceRoot: string
    renderedFallback?: RenderedWebFetchOptions
  }
): WorkerAgentTool<typeof WebFetchParams, WebToolDetails> {
  return defineWorkerTool({
    name: 'web_fetch',
    description: `Extract and return readable text from HTTPS web pages through AIGateway, with an internal rendered-page fallback when the provider is unavailable. This tool returns text only, never binary file content. Do not use web_fetch for PDFs, archives, images, audio/video, executables, or other binary files; use the command shell tool to run aria2c for those downloads. Pass all needed text-page URLs in one call. One call returns at most about ${WEB_FETCH_BUDGET_CHARS} characters of page text; a longer page shows its start and its end, its full text is saved in the workspace, and the result gives the file path and the read_file call that shows the omitted middle.`,
    schema: WebFetchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => webFetchActivity(params.urls),
    describeCompletedActivity: (params, details) => completedWebFetchActivity(params.urls, details),
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      let body: unknown

      try {
        body = await postAIGatewayJSON(aiGateway, '/web_fetch', { model: WebFetchSelector, urls: params.urls }, signal)
      } catch (error) {
        if (signal?.aborted || !config.renderedFallback) throw error
        body = await renderedFallbackFetch(params.urls, config.renderedFallback, signal, errorMessage(error))
      }

      const rendered = renderFetchedPages(body, { workspaceRoot: config.workspaceRoot })

      return {
        content: [{ type: 'text', text: rendered.text }],
        details: rendered.details
      }
    }
  })
}

/**
 * Fetches URLs through an ephemeral, materialized browser route.
 *
 * Per-URL errors are returned in the result array so one bad page does not hide
 * successful fetches from the model.
 */
async function renderedFallbackFetch(
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
      assertSafeRenderedFetchURL(url, config.ssrfFilter !== false)
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

  if (accepted.length > 0 && config.fetchBatch) {
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
  } else if (accepted.length > 0 && config.fetchURL) {
    for (const item of accepted) {
      try {
        results[item.index] = normalizeRenderedFetchResult(
          item.url,
          await config.fetchURL({ url: item.url, index: item.index }, signal)
        )
      } catch (error) {
        if (signal?.aborted) throw error
        results[item.index] = renderedFetchError(item.url, error)
      }
    }
  } else if (accepted.length > 0) {
    throw new Error('rendered fallback adapter is unavailable')
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

/**
 * Sends a JSON POST to an AIGateway web-tool endpoint and parses the response.
 */
async function postAIGatewayJSON(
  aiGateway: AIGatewayHTTPClient,
  path: string,
  body: JSONObject,
  signal?: AbortSignal
): Promise<unknown> {
  const response = await aiGateway.fetch(aiGatewayURL(aiGateway, path), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal
  })
  const text = await response.text()
  const parsed = parseJSON(text)

  if (!response.ok) {
    throw new Error(gatewayErrorMessage(parsed, response.status))
  }

  return parsed
}

/**
 * Formats search results for direct model consumption.
 */
function formatSearchResults(body: unknown): string {
  const results = Array.isArray(isRecord(body) ? body.results : undefined)
    ? (body as { results: unknown[] }).results
    : []
  if (results.length === 0) return 'No web search results.'

  return results
    .map((result, index) => {
      const item = isRecord(result) ? result : {}
      const title = stringField(item, 'title') || '(untitled)'
      const url = stringField(item, 'url')
      const snippet = stringField(item, 'snippet')
      return [`${index + 1}. ${title}`, url, snippet].filter(Boolean).join('\n')
    })
    .join('\n\n')
}

/**
 * Parses JSON, preserving raw text when the gateway returns non-JSON content.
 */
function parseJSON(text: string): unknown {
  if (!text) return {}
  return safeJSONParse(text).match({
    ok: value => value,
    err: () => ({ raw: text })
  })
}

/**
 * Builds a useful error message from an AIGateway web-tool failure response.
 */
function gatewayErrorMessage(body: unknown, status: number): string {
  const message = isRecord(body) ? deepString(body, ['error', 'message']) : undefined
  const code = isRecord(body) ? deepString(body, ['error', 'code']) : undefined
  return [`AIGateway web tool request failed with HTTP ${status}`, code, message || safeJSONStringify(body)]
    .filter(Boolean)
    .join(': ')
}

/**
 * Joins an AIGateway base URL and endpoint path.
 */
function aiGatewayURL(aiGateway: AIGatewayHTTPClient, path: string): string {
  return `${aiGateway.baseURL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`
}

/**
 * Ensures details are JSON-object-shaped for AgentToolResult.
 */
function detailsObject(value: unknown): JSONObject {
  return isRecord(value) ? value : { value }
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
 * Accepts HTTPS URLs for web_fetch, using the shared kernel URL parser.
 */
function isHTTPSURL(value: string): boolean {
  try {
    return webURLFacts(value).scheme === 'https'
  } catch {
    return false
  }
}

/**
 * Sanitizes the execution scope into a browser session id.
 */
function assertSafeRenderedFetchURL(value: string, ssrfFilter: boolean): void {
  const facts = webURLFacts(value)
  if (facts.hostClass === 'metadata') throw new Error('blocked rendered fetch to cloud metadata endpoint')
  if (ssrfFilter && facts.hostClass === 'private') {
    throw new Error('blocked non-public URL by the security.ssrf_filter policy')
  }
}
