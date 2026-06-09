/**
 * Web provider adapter contract shared by `web_search` and `web_extract`.
 *
 * Mirrors the Elixir `web_adapter` model: a single provider can support search,
 * extract, or both (e.g. exa). Built-in providers are registered at startup;
 * plugins contribute extra providers through the SDK `webProviders` field.
 */

export type WebProviderKind = 'search' | 'extract'

/** Normalized search hit returned to the model. */
export interface WebSearchResult {
  title: string
  url: string
  snippet: string
}

/** Normalized per-URL extraction result. `error` is set when that URL failed. */
export interface WebExtractResult {
  url: string
  title: string
  text: string
  error?: string
}

export interface WebSearchArgs {
  query: string
  limit?: number
}

export interface WebExtractArgs {
  urls: string[]
}

export interface WebProvider {
  readonly id: string
  readonly supports: readonly WebProviderKind[]
  /**
   * Whether this provider is usable now for `kind` (key configured, or no key
   * needed). May read config, hence async-capable.
   */
  available(kind: WebProviderKind): boolean | Promise<boolean>
  unavailableReason?(kind: WebProviderKind): string | undefined | Promise<string | undefined>
  search?(args: WebSearchArgs, signal?: AbortSignal): Promise<WebSearchResult[]>
  extract?(args: WebExtractArgs, signal?: AbortSignal): Promise<WebExtractResult[]>
}

export interface WebProviderErrorOptions {
  retryable: boolean
  providerId: string
  status?: number
}

/**
 * Error raised by providers and routing. `retryable` flows back into the tool
 * result so the model/loop can decide whether to retry (429/5xx => retryable).
 */
export class WebProviderError extends Error {
  readonly retryable: boolean
  readonly providerId: string
  readonly status?: number

  constructor(message: string, options: WebProviderErrorOptions) {
    super(message)
    this.name = 'WebProviderError'
    this.retryable = options.retryable
    this.providerId = options.providerId
    this.status = options.status
  }
}
