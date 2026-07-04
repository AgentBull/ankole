import { z } from 'zod'
import type { JsonObject } from '../../lanes/actor_lane'
import { browserExtractFromSession, ensureBrowserSession, type BrowserRuntimeOptions } from '../browser/cdp'
import { isRecord, safeJsonStringify } from '../../common/json-utils'
import type { AgentTool, AgentToolResult } from '../../core'
import type { AIGatewayHttpClient } from '../../core/turns/model_runtime'

type WebToolDetails = JsonObject

interface WebToolAvailability {
  available?: boolean
  model?: string
  reason?: string
}

interface WebToolsResponse {
  web_search?: WebToolAvailability
  web_fetch?: WebToolAvailability
}

export interface CreateWebToolsOptions {
  aiGateway: AIGatewayHttpClient
  localBrowser?: LocalBrowserWebFetchOptions
}

export interface LocalBrowserWebFetchOptions {
  agentUid: string
  executionScopeId?: string | null
  localBrowserIdleTtlMs?: number
  fetchUrl?: LocalBrowserFetchUrl
}

export type LocalBrowserFetchUrl = (input: { url: string; index: number }, signal?: AbortSignal) => Promise<unknown>

const WebSearchParams = z.object({
  query: z.string().min(1).max(500).describe('Search query.'),
  limit: z.number().int().min(1).max(100).optional().describe('Maximum result count. Defaults to 5.')
})

const HttpsUrl = z
  .string()
  .url()
  .refine(value => isHttpsUrl(value), 'Only HTTPS URLs are supported.')

const WebFetchParams = z.object({
  urls: z.array(HttpsUrl).min(1).max(5).describe('Public HTTPS URLs to fetch. Maximum 5.')
})

/**
 * Creates web tools based on AIGateway-reported provider availability.
 *
 * The local browser can provide web_fetch as a fallback, but web_search remains
 * provider-backed because the worker does not own a search index.
 */
export async function createWebTools(opts: CreateWebToolsOptions): Promise<AgentTool<any>[]> {
  const availability = await fetchWebToolsAvailability(opts.aiGateway)
  const tools: AgentTool<any>[] = []

  if (availability.web_search?.available && availability.web_search.model) {
    tools.push(createWebSearchTool(opts.aiGateway, availability.web_search.model))
  }

  const providerFetchModel =
    availability.web_fetch?.available && availability.web_fetch.model ? availability.web_fetch.model : undefined
  if (providerFetchModel || opts.localBrowser) {
    tools.push(
      createWebFetchTool(opts.aiGateway, {
        providerModel: providerFetchModel,
        localBrowser: opts.localBrowser
      })
    )
  }

  return tools
}

/**
 * Builds the provider-backed web_search tool.
 */
function createWebSearchTool(
  aiGateway: AIGatewayHttpClient,
  model: string
): AgentTool<typeof WebSearchParams, WebToolDetails> {
  return {
    name: 'web_search',
    description: 'Search the public web through the configured AIGateway web search provider.',
    schema: WebSearchParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      const body = await postAIGatewayJson(
        aiGateway,
        '/web_search',
        {
          model,
          query: params.query,
          ...(params.limit ? { limit: params.limit } : {})
        },
        signal
      )

      return {
        content: [{ type: 'text', text: formatSearchResults(body) }],
        details: jsonObject(body)
      }
    }
  }
}

/**
 * Builds web_fetch with provider-first and optional local-browser fallback.
 *
 * Provider fetch is preferred when configured because it can use gateway-owned
 * extraction services. The browser fallback keeps rendered pages reachable when
 * the provider path is unavailable.
 */
function createWebFetchTool(
  aiGateway: AIGatewayHttpClient,
  config: {
    providerModel?: string
    localBrowser?: LocalBrowserWebFetchOptions
  }
): AgentTool<typeof WebFetchParams, WebToolDetails> {
  const description = config.providerModel
    ? 'Fetch readable text from public HTTPS web pages through AIGateway, falling back to the local browser when available.'
    : 'Fetch readable text from public HTTPS web pages through the local browser.'

  return {
    name: 'web_fetch',
    description,
    schema: WebFetchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      let body: unknown

      if (config.providerModel) {
        try {
          body = await postAIGatewayJson(
            aiGateway,
            '/web_fetch',
            { model: config.providerModel, urls: params.urls },
            signal
          )
        } catch (error) {
          if (signal?.aborted) throw error
          if (!config.localBrowser) throw error
          body = await localBrowserFetch(params.urls, config.localBrowser, signal, errorMessage(error))
        }
      } else if (config.localBrowser) {
        body = await localBrowserFetch(params.urls, config.localBrowser, signal)
      } else {
        throw new Error(
          'web_fetch is unavailable: no AIGateway provider profile or local browser fallback is configured'
        )
      }

      return {
        content: [{ type: 'text', text: formatFetchResults(body) }],
        details: jsonObject(body)
      }
    }
  }
}

/**
 * Fetches URLs through a persistent local browser session.
 *
 * Per-URL errors are returned in the result array so one bad page does not hide
 * successful fetches from the model.
 */
async function localBrowserFetch(
  urls: string[],
  config: LocalBrowserWebFetchOptions,
  signal?: AbortSignal,
  fallbackReason?: string
): Promise<JsonObject> {
  const fetchUrl = config.fetchUrl ?? createLocalBrowserFetchUrl(config)
  const results: JsonObject[] = []

  for (const [index, url] of urls.entries()) {
    if (signal?.aborted) throw new Error('web_fetch aborted')
    try {
      if (!isHttpsUrl(url)) throw new Error('Only HTTPS URLs are supported.')
      const result = await fetchUrl({ url, index }, signal)
      results.push(normalizeLocalBrowserFetchResult(url, result))
    } catch (error) {
      if (signal?.aborted) throw error
      results.push({
        url,
        error: errorMessage(error),
        metadata: {
          source: 'local_browser'
        }
      })
    }
  }

  return {
    success: results.every(result => typeof result.error !== 'string'),
    source: 'local_browser',
    ...(fallbackReason ? { fallback_from: 'aigateway', fallback_reason: fallbackReason } : {}),
    results
  }
}

/**
 * Creates the URL fetcher used by local-browser web_fetch.
 *
 * The session name is scoped to the agent/session so cookies and page state can
 * persist during a turn without leaking across unrelated execution scopes.
 */
function createLocalBrowserFetchUrl(config: LocalBrowserWebFetchOptions): LocalBrowserFetchUrl {
  const executionScopeId = sanitizeWebFetchId(config.executionScopeId || config.agentUid || 'default')
  const session = `web-fetch-${executionScopeId}`
  const options: BrowserRuntimeOptions = {
    remoteCdpConfig: null,
    ...(typeof config.localBrowserIdleTtlMs === 'number' ? { localBrowserIdleTtlMs: config.localBrowserIdleTtlMs } : {})
  }
  let sessionReady = false

  return async ({ url, index }, signal) => {
    if (signal?.aborted) throw new Error('web_fetch aborted')
    if (!sessionReady) {
      await ensureBrowserSession({ session }, options)
      sessionReady = true
    }
    const extracted = await browserExtractFromSession({ session, url, taskId: `web-fetch-${index + 1}` }, options)
    if (!extracted) throw new Error('local browser returned no extract result')
    return extracted
  }
}

/**
 * Normalizes browser extract output into the same rough result shape as
 * provider web_fetch.
 */
function normalizeLocalBrowserFetchResult(url: string, value: unknown): JsonObject {
  const record = isRecord(value) ? value : { text: String(value ?? '') }
  const metadata = isRecord(record.metadata) ? record.metadata : {}
  const result: JsonObject = {
    url: stringField(record, 'url') || url,
    title: stringField(record, 'title'),
    text: stringField(record, 'text') || '',
    metadata: {
      ...metadata,
      source: 'local_browser',
      ...(stringField(record, 'backend') ? { backend: stringField(record, 'backend') } : {}),
      ...(stringField(record, 'adapter') ? { adapter: stringField(record, 'adapter') } : {}),
      ...(stringField(record, 'session') ? { session: stringField(record, 'session') } : {})
    }
  }

  const error = stringField(record, 'error')
  if (error) result.error = error
  return result
}

/**
 * Reads the web-tool availability document from AIGateway.
 */
async function fetchWebToolsAvailability(aiGateway: AIGatewayHttpClient): Promise<WebToolsResponse> {
  try {
    const response = await aiGateway.fetch(aiGatewayUrl(aiGateway, '/web_tools'))
    if (!response.ok) return {}
    const body = await response.json()
    return isRecord(body) ? (body as WebToolsResponse) : {}
  } catch {
    return {}
  }
}

/**
 * Sends a JSON POST to an AIGateway web-tool endpoint and parses the response.
 */
async function postAIGatewayJson(
  aiGateway: AIGatewayHttpClient,
  path: string,
  body: JsonObject,
  signal?: AbortSignal
): Promise<unknown> {
  const response = await aiGateway.fetch(aiGatewayUrl(aiGateway, path), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal
  })
  const text = await response.text()
  const parsed = parseJson(text)

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
 * Formats fetched page text and errors for direct model consumption.
 */
function formatFetchResults(body: unknown): string {
  const bodyRecord = isRecord(body) ? body : {}
  const bodySource = stringField(bodyRecord, 'source')
  const results = Array.isArray(isRecord(body) ? body.results : undefined)
    ? (body as { results: unknown[] }).results
    : []
  if (results.length === 0) return 'No web fetch results.'

  return results
    .map(result => {
      const item = isRecord(result) ? result : {}
      const metadata = isRecord(item.metadata) ? item.metadata : {}
      const url = stringField(item, 'url')
      const title = stringField(item, 'title')
      const error = stringField(item, 'error')
      const text = stringField(item, 'text')
      const source = stringField(metadata, 'source') || bodySource
      if (error) {
        return [`URL: ${url || '(unknown)'}`, source ? `Source: ${source}` : '', `Error: ${error}`]
          .filter(Boolean)
          .join('\n')
      }
      return [`URL: ${url || '(unknown)'}`, source ? `Source: ${source}` : '', title ? `Title: ${title}` : '', text]
        .filter(Boolean)
        .join('\n')
    })
    .join('\n\n---\n\n')
}

/**
 * Parses JSON, preserving raw text when the gateway returns non-JSON content.
 */
function parseJson(text: string): unknown {
  if (!text) return {}
  try {
    return JSON.parse(text)
  } catch {
    return { raw: text }
  }
}

/**
 * Builds a useful error message from an AIGateway web-tool failure response.
 */
function gatewayErrorMessage(body: unknown, status: number): string {
  const message = isRecord(body) ? deepString(body, ['error', 'message']) : undefined
  const code = isRecord(body) ? deepString(body, ['error', 'code']) : undefined
  return [`AIGateway web tool request failed with HTTP ${status}`, code, message || safeJsonStringify(body)]
    .filter(Boolean)
    .join(': ')
}

/**
 * Joins an AIGateway base URL and endpoint path.
 */
function aiGatewayUrl(aiGateway: AIGatewayHttpClient, path: string): string {
  return `${aiGateway.baseURL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`
}

/**
 * Ensures details are JSON-object-shaped for AgentToolResult.
 */
function jsonObject(value: unknown): JsonObject {
  return isRecord(value) ? value : { value }
}

/**
 * Reads a non-empty string field from a JSON object.
 */
function stringField(record: JsonObject, key: string): string | undefined {
  const value = record[key]
  return typeof value === 'string' && value.trim() ? value : undefined
}

/**
 * Reads a nested string from a JSON object.
 */
function deepString(record: JsonObject, path: string[]): string | undefined {
  let current: unknown = record
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' ? current : undefined
}

/**
 * Accepts only public HTTPS URLs for web_fetch.
 */
function isHttpsUrl(value: string): boolean {
  try {
    return new URL(value).protocol === 'https:'
  } catch {
    return false
  }
}

/**
 * Sanitizes the execution scope into a browser session id.
 */
function sanitizeWebFetchId(value: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || 'default'
}

/**
 * Converts unknown thrown values into readable text.
 */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
