import { isRecord, ms } from '@agentbull/active-support'
import { errorMessage } from '../common/errors'
import { rm } from 'node:fs/promises'
import { BrowserDataError, BrowserErrorCodeSchema, sendBrowserCommand, type BrowserErrorCode } from '@ankole/browser'
import type { BrowserRouteMaterializer, BrowserRoute, RenderedFetchBrowserMaterializeSettings } from './materializer'

const RenderedFetchTimeoutMs = ms('5m')

export type BrowserWebFetchFailureEvent = {
  backendKind: BrowserRoute['material']['backend']['kind']
  stage: 'invoke' | 'url'
  errorCode: BrowserErrorCode
  errorMessage: string
  retryable: boolean
  urlIndex?: number
  urlScheme?: string
  urlHost?: string
}

type BrowserWebFetchAdapterOptions = {
  ensureDaemon?: () => Promise<void>
  onFailure?: (event: BrowserWebFetchFailureEvent) => void
}

export class BrowserWebFetchAdapter {
  constructor(
    readonly materializer: BrowserRouteMaterializer,
    private readonly options: BrowserWebFetchAdapterOptions = {}
  ) {}

  async fetch(
    urls: string[],
    settings: RenderedFetchBrowserMaterializeSettings,
    signal?: AbortSignal
  ): Promise<unknown> {
    const runtime = await this.materializer.materializeEphemeral({ settings })
    try {
      let result: unknown
      try {
        const response = await sendBrowserCommand(
          { ...runtime, timeoutMs: RenderedFetchTimeoutMs },
          { name: 'fetch', args: { urls } },
          { timeoutMs: RenderedFetchTimeoutMs, signal }
        )
        if (!response.ok) {
          throw new BrowserDataError(response.error.code, response.error.message, {
            retryable: response.error.retryable,
            details: response.error.details
          })
        }
        result = response.data
      } catch (error) {
        if (!signal?.aborted) this.reportFailure(runtime, { stage: 'invoke', ...observedFailure(error) })
        throw error
      }
      this.reportResultFailures(runtime, result, urls)
      return result
    } finally {
      await this.purge(runtime)
      await rm(runtime.artifactRoot, { recursive: true, force: true })
    }
  }

  private reportResultFailures(runtime: BrowserRoute, value: unknown, urls: string[]): void {
    if (!isRecord(value) || !Array.isArray(value.results)) return
    for (const [urlIndex, result] of value.results.entries()) {
      if (!isRecord(result) || typeof result.error !== 'string') continue
      const parsedCode = BrowserErrorCodeSchema.safeParse(result.error_code)
      this.reportFailure(runtime, {
        stage: 'url',
        errorCode: parsedCode.success ? parsedCode.data : 'internal',
        errorMessage: redactedErrorMessage(result.error),
        retryable: result.retryable === true,
        urlIndex,
        ...safeURLLogFields(urls[urlIndex])
      })
    }
  }

  private reportFailure(runtime: BrowserRoute, failure: Omit<BrowserWebFetchFailureEvent, 'backendKind'>): void {
    try {
      this.options.onFailure?.({ backendKind: runtime.material.backend.kind, ...failure })
    } catch {
      // Observability must not change fetch behavior.
    }
  }

  private async purge(runtime: BrowserRoute): Promise<void> {
    const send = async (): Promise<void> => {
      const response = await sendBrowserCommand(
        {
          socketPath: runtime.socketPath,
          route: runtime.route,
          session: runtime.session,
          material: runtime.material,
          artifactRoot: runtime.artifactRoot,
          timeoutMs: ms('5s')
        },
        { name: 'lifecycle', args: { verb: 'purge' } },
        { timeoutMs: ms('5s') }
      )
      if (!response.ok) throw new BrowserDataError(response.error.code, response.error.message)
    }

    try {
      await send()
    } catch {
      if (!this.options.ensureDaemon) return
      await this.options.ensureDaemon().catch(() => undefined)
      await send().catch(() => undefined)
    }
  }
}

function observedFailure(
  error: unknown
): Pick<BrowserWebFetchFailureEvent, 'errorCode' | 'errorMessage' | 'retryable'> {
  return {
    errorCode: error instanceof BrowserDataError ? error.code : 'internal',
    errorMessage: redactedErrorMessage(errorMessage(error)),
    retryable: error instanceof BrowserDataError && error.retryable
  }
}

function redactedErrorMessage(value: string): string {
  const firstLine = value.split(/\r?\n/)[0]?.trim() || 'browser fetch failed'
  return firstLine
    .replace(/\b(?:https?|wss?):\/\/[^\s"'<>]+/gi, '[redacted endpoint]')
    .replace(
      /\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*[:=]\s*[^\s,;]+/gi,
      '$1=[redacted]'
    )
    .slice(0, 500)
}

function safeURLLogFields(value: string | undefined): Pick<BrowserWebFetchFailureEvent, 'urlScheme' | 'urlHost'> {
  if (!value) return {}

  try {
    const url = new URL(value)
    return {
      urlScheme: url.protocol.replace(/:$/, ''),
      urlHost: url.host
    }
  } catch {
    return {}
  }
}
