import { z } from 'zod'
import { webURLFacts } from '@ankole/kernel'
import {
  deepString,
  isRecord,
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify
} from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import {
  assertSafeBrowserURL,
  browserExtractFromSession,
  ensureBrowserSession,
  type BrowserRuntimeOptions
} from '../browser/cdp'
import type { AgentTool, AgentToolResult } from '../../core'
import type { AIGatewayHTTPClient } from '../../core/ai_gateway_transport'
import { errorMessage } from '../../common/errors'

type WebToolDetails = JSONObject

interface WebToolAvailability {
  available?: boolean
  model?: string
  reason?: string
}

interface WebToolsResponse {
  web_search?: WebToolAvailability
  web_fetch?: WebToolAvailability
}

type WebToolsAvailabilityResolver = (signal?: AbortSignal) => Promise<WebToolsResponse>

export interface CreateWebToolsOptions {
  aiGateway: AIGatewayHTTPClient
  abortSignal?: AbortSignal
  localBrowser?: LocalBrowserWebFetchOptions
}

export interface LocalBrowserWebFetchOptions {
  agentUID: string
  executionScopeID?: string | null
  localBrowserIdleTtlMs?: number
  ssrfFilter?: boolean
  fetchURL?: LocalBrowserFetchURL
}

export type LocalBrowserFetchURL = (input: { url: string; index: number }, signal?: AbortSignal) => Promise<unknown>

const WebSearchParams = z.object({
  query: z.string().min(1).max(500).describe('Search query.'),
  limit: z.number().int().min(1).max(100).optional().describe('Maximum result count. Defaults to 5.')
})

const HTTPSURL = z
  .string()
  .url()
  .refine(value => isHTTPSURL(value), 'Only HTTPS URLs are supported.')

const WebFetchParams = z.object({
  urls: z.array(HTTPSURL).min(1).max(5).describe('HTTPS URLs to fetch. Maximum 5.')
})

/**
 * Creates a stable web-tool catalog and resolves provider availability lazily.
 *
 * Provider configuration may change between turns, but the model-facing tool
 * definitions must not. Each turn memoizes the first availability lookup;
 * web_fetch can fall back to the local browser, while web_search remains
 * provider-backed because the worker does not own a search index.
 */
export async function createWebTools(opts: CreateWebToolsOptions): Promise<AgentTool<any>[]> {
  let availabilityPromise: Promise<WebToolsResponse> | undefined
  const resolveAvailability: WebToolsAvailabilityResolver = signal => {
    availabilityPromise ??= fetchWebToolsAvailability(opts.aiGateway, signal ?? opts.abortSignal)
    return availabilityPromise
  }

  return [
    createWebSearchTool(opts.aiGateway, resolveAvailability),
    createWebFetchTool(opts.aiGateway, {
      resolveAvailability,
      localBrowser: opts.localBrowser
    })
  ]
}

/**
 * Builds the provider-backed web_search tool.
 */
function createWebSearchTool(
  aiGateway: AIGatewayHTTPClient,
  resolveAvailability: WebToolsAvailabilityResolver
): AgentTool<typeof WebSearchParams, WebToolDetails> {
  return {
    name: 'web_search',
    description: 'Search the public web through the configured AIGateway web search provider.',
    schema: WebSearchParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      const availability = await resolveAvailability(signal)
      const model = configuredProviderModel('web_search', availability.web_search)
      const body = await postAIGatewayJSON(
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
        details: detailsObject(body)
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
  aiGateway: AIGatewayHTTPClient,
  config: {
    resolveAvailability: WebToolsAvailabilityResolver
    localBrowser?: LocalBrowserWebFetchOptions
  }
): AgentTool<typeof WebFetchParams, WebToolDetails> {
  return {
    name: 'web_fetch',
    description:
      'Fetch readable text from HTTPS web pages through AIGateway, falling back to the local browser when available. Pass all needed URLs in one call.',
    schema: WebFetchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      let body: unknown
      let providerModel: string | undefined

      try {
        const availability = await config.resolveAvailability(signal)
        providerModel = optionalProviderModel(availability.web_fetch)
        if (!providerModel && !config.localBrowser) {
          configuredProviderModel('web_fetch', availability.web_fetch)
        }
      } catch (error) {
        if (signal?.aborted || !config.localBrowser) throw error
        body = await localBrowserFetch(params.urls, config.localBrowser, signal, errorMessage(error))
      }

      if (body === undefined && providerModel) {
        try {
          body = await postAIGatewayJSON(aiGateway, '/web_fetch', { model: providerModel, urls: params.urls }, signal)
        } catch (error) {
          if (signal?.aborted) throw error
          if (!config.localBrowser) throw error
          body = await localBrowserFetch(params.urls, config.localBrowser, signal, errorMessage(error))
        }
      } else if (body === undefined && config.localBrowser) {
        body = await localBrowserFetch(params.urls, config.localBrowser, signal)
      }

      return {
        content: [{ type: 'text', text: formatFetchResults(body) }],
        details: detailsObject(body)
      }
    }
  }
}

/** Returns a configured provider model or explains why the tool cannot run. */
function configuredProviderModel(name: 'web_search' | 'web_fetch', availability?: WebToolAvailability): string {
  const model = optionalProviderModel(availability)
  if (model) return model

  const reason = availability?.reason?.trim()
  throw new Error(`${name} is unavailable: ${reason || 'no AIGateway provider model is configured'}`)
}

/** Reads a usable provider model from one availability entry. */
function optionalProviderModel(availability?: WebToolAvailability): string | undefined {
  return availability?.available && availability.model?.trim() ? availability.model.trim() : undefined
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
): Promise<JSONObject> {
  const fetchURL = config.fetchURL ?? createLocalBrowserFetchURL(config)
  const results: JSONObject[] = []

  for (const [index, url] of urls.entries()) {
    if (signal?.aborted) throw new Error('web_fetch aborted')
    try {
      if (!isHTTPSURL(url)) throw new Error('Only HTTPS URLs are supported.')
      // Same guard the browser session applies on navigation; checking here
      // fails fast without starting a Chromium sidecar for a rejected URL.
      assertSafeBrowserURL(url, { ssrfFilter: config.ssrfFilter === true })
      const result = await fetchURL({ url, index }, signal)
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
function createLocalBrowserFetchURL(config: LocalBrowserWebFetchOptions): LocalBrowserFetchURL {
  const executionScopeID = sanitizeWebFetchID(config.executionScopeID || config.agentUID || 'default')
  const session = `web-fetch-${executionScopeID}`
  const options: BrowserRuntimeOptions = {
    remoteCDPConfig: null,
    ssrfFilter: config.ssrfFilter === true,
    ...(typeof config.localBrowserIdleTtlMs === 'number' ? { localBrowserIdleTtlMs: config.localBrowserIdleTtlMs } : {})
  }
  let sessionReady = false

  return async ({ url, index }, signal) => {
    if (signal?.aborted) throw new Error('web_fetch aborted')
    if (!sessionReady) {
      await ensureBrowserSession({ session }, options)
      sessionReady = true
    }
    const extracted = await browserExtractFromSession({ session, url, taskID: `web-fetch-${index + 1}` }, options)
    if (!extracted) throw new Error('local browser returned no extract result')
    return extracted
  }
}

/**
 * Normalizes browser extract output into the same rough result shape as
 * provider web_fetch.
 */
function normalizeLocalBrowserFetchResult(url: string, value: unknown): JSONObject {
  const record = isRecord(value) ? value : { text: String(value ?? '') }
  const metadata = isRecord(record.metadata) ? record.metadata : {}
  const result: JSONObject = {
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
async function fetchWebToolsAvailability(
  aiGateway: AIGatewayHTTPClient,
  signal?: AbortSignal
): Promise<WebToolsResponse> {
  const response = await aiGateway.fetch(aiGatewayURL(aiGateway, '/web_tools'), { signal })
  const text = await response.text()
  const body = parseJSON(text)

  if (!response.ok) {
    throw new Error(gatewayErrorMessage(body, response.status))
  }
  if (!isRecord(body)) throw new Error('AIGateway web tool availability returned a non-object response')

  return body as WebToolsResponse
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
function parseJSON(text: string): unknown {
  if (!text) return {}
  return safeJSONParse(text).match(
    value => value,
    () => ({ raw: text })
  )
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

/**
 * Reads a non-empty string field from a JSON object.
 */
function stringField(record: JSONObject, key: string): string | undefined {
  const value = record[key]
  return typeof value === 'string' && value.trim() ? value : undefined
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
function sanitizeWebFetchID(value: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || 'default'
}
