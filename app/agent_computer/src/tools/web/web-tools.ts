import { z } from 'zod'
import { webURLFacts } from '@ankole/kernel'
import {
  deepString,
  isRecord,
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify
} from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
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
const RenderedFallbackSource = 'rendered_fallback'

export interface CreateWebToolsOptions {
  aiGateway: AIGatewayHTTPClient
  abortSignal?: AbortSignal
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
 * Creates a stable web-tool catalog and resolves provider availability lazily.
 *
 * Provider configuration may change between turns, but the model-facing tool
 * definitions must not. Each turn memoizes the first availability lookup;
 * web_fetch can fall back to an internal rendered-page extractor, while web_search remains
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
      renderedFallback: opts.renderedFallback
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
    describeActivity: params => `搜索网页：“${activityExcerpt(params.query, 48)}”`,
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
 * Builds web_fetch with provider-first and an optional rendered-page fallback.
 *
 * Provider fetch is preferred when configured because it can use gateway-owned
 * extraction services. The internal fallback keeps rendered pages reachable when
 * the provider path is unavailable.
 */
function createWebFetchTool(
  aiGateway: AIGatewayHTTPClient,
  config: {
    resolveAvailability: WebToolsAvailabilityResolver
    renderedFallback?: RenderedWebFetchOptions
  }
): AgentTool<typeof WebFetchParams, WebToolDetails> {
  return {
    name: 'web_fetch',
    description:
      'Extract and return readable text from HTTPS web pages through AIGateway, with an internal rendered-page fallback when the provider is unavailable. This tool returns text only, never binary file content. Do not use web_fetch for PDFs, archives, images, audio/video, executables, or other binary files; use the command shell tool to run aria2c for those downloads. Pass all needed text-page URLs in one call.',
    schema: WebFetchParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: params => webFetchActivity(params.urls),
    describeCompletedActivity: (params, details) => completedWebFetchActivity(params.urls, details),
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebToolDetails>> {
      let body: unknown
      let providerModel: string | undefined

      try {
        const availability = await config.resolveAvailability(signal)
        providerModel = optionalProviderModel(availability.web_fetch)
        if (!providerModel && !config.renderedFallback) {
          configuredProviderModel('web_fetch', availability.web_fetch)
        }
      } catch (error) {
        if (signal?.aborted || !config.renderedFallback) throw error
        body = await renderedFallbackFetch(params.urls, config.renderedFallback, signal, errorMessage(error))
      }

      if (body === undefined && providerModel) {
        try {
          body = await postAIGatewayJSON(aiGateway, '/web_fetch', { model: providerModel, urls: params.urls }, signal)
        } catch (error) {
          if (signal?.aborted) throw error
          if (!config.renderedFallback) throw error
          body = await renderedFallbackFetch(params.urls, config.renderedFallback, signal, errorMessage(error))
        }
      } else if (body === undefined && config.renderedFallback) {
        body = await renderedFallbackFetch(params.urls, config.renderedFallback, signal)
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

/** Builds a parameter-only label before web_fetch returns page metadata. */
function webFetchActivity(urls: string[]): string {
  const domain = webDomain(urls[0])
  const target = domain || '网页'
  return urls.length === 1 ? `读取网页：${target}` : `读取网页：${target} 等 ${urls.length} 个网页`
}

/** Adds a returned page title without exposing fetched body text or URL parameters. */
function completedWebFetchActivity(urls: string[], details: WebToolDetails): string {
  const results = Array.isArray(details.results) ? details.results : []
  const firstTitled = results.find(result => isRecord(result) && stringField(result, 'title'))
  const firstResult = firstTitled ?? results.find(isRecord)
  const record = isRecord(firstResult) ? firstResult : undefined
  const title = record ? stringField(record, 'title') : undefined
  const domain = webDomain(record ? stringField(record, 'url') : undefined) || webDomain(urls[0])
  const titlePart = title ? `《${activityExcerpt(title, 40)}》` : undefined
  const target = [titlePart, domain].filter(Boolean).join(' · ') || '网页'

  return urls.length === 1 ? `读取网页：${target}` : `读取网页：${target} 等 ${urls.length} 个网页`
}

function webDomain(value?: string): string | undefined {
  if (!value) return undefined
  try {
    return webURLFacts(value).host || undefined
  } catch {
    return undefined
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

/**
 * Reads a non-empty string field from a JSON object.
 */
function stringField(record: JSONObject, key: string): string | undefined {
  const value = record[key]
  return typeof value === 'string' && value.trim() ? value : undefined
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
